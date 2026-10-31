package isureal

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
)

// nginx の internal location。provisioning/nginx/sites-available/isureal.conf と揃えること。
const imageCacheInternalPrefix = "/internal/images/"

var imageCacheIDPattern = regexp.MustCompile(`^[0-9a-zA-Z-]{2,36}$`)

// ImageCache は image_objects の内容をサーバーごとにファイルへ複製する。
// 正のデータは DB にあり、ファイルはいつ消えても read-through で復元できる。
// 画像は ID ごとに不変で、取得可否は配信前に毎回 DB で確認するため、
// 他サーバーで削除された画像のファイルが残っていても配信はされない。
type ImageCache struct {
	Dir string
}

func (ic *ImageCache) relativePath(imageID string) (string, bool) {
	if !imageCacheIDPattern.MatchString(imageID) {
		return "", false
	}
	return imageID[:2] + "/" + imageID, true
}

// AccelPath はファイルがあれば X-Accel-Redirect に渡すパスを返す。
func (ic *ImageCache) AccelPath(imageID string) (string, bool) {
	relativePath, ok := ic.relativePath(imageID)
	if !ok {
		return "", false
	}
	if _, err := os.Stat(filepath.Join(ic.Dir, relativePath)); err != nil {
		return "", false
	}
	return imageCacheInternalPrefix + relativePath, true
}

// Put はファイルを書き込む。失敗しても DB から配信できるのでログだけ残す。
func (ic *ImageCache) Put(imageID string, data []byte) bool {
	relativePath, ok := ic.relativePath(imageID)
	if !ok {
		return false
	}
	if err := ic.write(relativePath, data); err != nil {
		log.Printf("failed to write image cache: %v", err)
		return false
	}
	return true
}

func (ic *ImageCache) write(relativePath string, data []byte) error {
	path := filepath.Join(ic.Dir, relativePath)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// nginx が書きかけのファイルを配信しないよう rename で置く。
	file, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Chmod(file.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func (ic *ImageCache) Remove(imageID string) {
	relativePath, ok := ic.relativePath(imageID)
	if !ok {
		return
	}
	if err := os.Remove(filepath.Join(ic.Dir, relativePath)); err != nil && !os.IsNotExist(err) {
		log.Printf("failed to remove image cache: %v", err)
	}
}
