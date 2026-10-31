package isureal

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"strconv"
	"sync"
	"time"
)

const imageURLLifetime = 24 * time.Hour
const imageSignatureIterations = 1000

func imageSigningKey(secretKeyHash string) ([]byte, error) {
	key, err := hex.DecodeString(secretKeyHash)
	if err != nil || len(key) != sha256.Size {
		return nil, fmt.Errorf("invalid image signing key")
	}
	return key, nil
}

type imageSigCacheEntry struct {
	sig []byte
	exp int64
}

// imageSigCache は (imageID, exp) -> signature のキャッシュ。
// exp は Unix秒単位で24時間後を指すため、同一 imageID への呼び出しは
// 1秒以内であれば同じ exp を持ち、高いヒット率が得られる。
var imageSigCache sync.Map // key: string("imageID:exp") -> imageSigCacheEntry

func imageSignature(key []byte, imageID string, exp int64) []byte {
	cacheKey := imageID + ":" + strconv.FormatInt(exp, 10)
	if v, ok := imageSigCache.Load(cacheKey); ok {
		return v.(imageSigCacheEntry).sig
	}

	value := []byte(strconv.FormatInt(exp, 10) + ":" + imageID)
	for range imageSignatureIterations {
		mac := hmac.New(sha256.New, key)
		mac.Write(value)
		value = mac.Sum(nil)
	}

	imageSigCache.Store(cacheKey, imageSigCacheEntry{sig: value, exp: exp})
	return value
}

// purgeExpiredImageSigCache は期限切れのキャッシュエントリを削除する。
// サーバー起動時にバックグラウンドで定期実行すること。
func purgeExpiredImageSigCache() {
	now := time.Now().Unix()
	imageSigCache.Range(func(k, v any) bool {
		if v.(imageSigCacheEntry).exp <= now {
			imageSigCache.Delete(k)
		}
		return true
	})
}

func signedImageURL(user User, imageID string) string {
	exp := time.Now().Add(imageURLLifetime).Unix()
	query := url.Values{
		"exp": {strconv.FormatInt(exp, 10)},
		"sig": {base64.RawURLEncoding.EncodeToString(imageSignature(user.ImageKey, imageID, exp))},
	}
	return "/api/images/" + url.PathEscape(imageID) + "?" + query.Encode()
}
