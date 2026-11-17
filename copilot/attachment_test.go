package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadLargeAttachment(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "fixture")
	expected := bytes.Repeat([]byte{255, 7, 0, 128, 3}, 17*1024*1024/5+1)
	if err := os.WriteFile(path, expected, 0600); err != nil {
		t.Fatal(err)
	}
	file := attachment{Name: "资料.unknown", MediaType: "application/octet-stream", Path: path, Size: int64(len(expected))}
	blob, err := file.load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	data, err := base64.StdEncoding.DecodeString(*blob.Data)
	if err != nil || !bytes.Equal(data, expected) || *blob.DisplayName != file.Name || blob.MIMEType != file.MediaType {
		t.Fatal("the SDK attachment did not preserve the source bytes and metadata", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := file.load(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation did not interrupt attachment preparation", err)
	}
	changed := file
	changed.Size--
	if _, err := changed.load(context.Background()); err == nil {
		t.Fatal("accepted incorrect file size")
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	file.Path = link
	if _, err := file.load(context.Background()); err == nil {
		t.Fatal("accepted symlink")
	}
}
