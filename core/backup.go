package aauvcore

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
)

const (
	backupManifestName = "manifest.json"
	backupFilePrefix   = "attachments/"
	maxBackupManifest  = 64 << 20
	maxBackupEntries   = 100_000
)

type backupAttachment struct {
	Name string `json:"fileName"`
	Size int64  `json:"size"`
}

type backupConversation struct {
	Attachments []backupAttachment `json:"attachments"`
	Messages    []struct {
		Attachments []backupAttachment `json:"attachments"`
	} `json:"messages"`
}

type zipFiles map[string]int64

func (files zipFiles) add(attachments []backupAttachment) error {
	for _, file := range attachments {
		if !isBackupFileName(file.Name) || file.Size < 0 {
			return errors.New("invalid_archive_attachment")
		}
		if size, exists := files[file.Name]; exists && size != file.Size {
			return errors.New("conflicting_archive_attachment")
		}
		files[file.Name] = file.Size
		if len(files) > maxBackupEntries {
			return errors.New("too_many_archive_attachments")
		}
	}
	return nil
}

func backupFiles(manifest []byte) (zipFiles, error) {
	var header struct {
		Version       int                  `json:"version"`
		Conversations []backupConversation `json:"conversations"`
	}
	if json.Unmarshal(manifest, &header) != nil || header.Version != 2 {
		return nil, errors.New("invalid_backup_manifest")
	}
	files := make(zipFiles)
	for _, conversation := range header.Conversations {
		if err := files.add(conversation.Attachments); err != nil {
			return nil, err
		}
		for _, message := range conversation.Messages {
			if err := files.add(message.Attachments); err != nil {
				return nil, err
			}
		}
	}
	return files, nil
}

func isBackupFileName(name string) bool {
	if len(name) != 36 {
		return false
	}
	for index, ch := range name {
		switch index {
		case 8, 13, 18, 23:
			if ch != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdefABCDEF", ch) {
				return false
			}
		}
	}
	return true
}

// WriteBackupZIP streams local attachments into a new ZIP without expanding
// them into JSON. Attachment entries are stored, which bounds restore size.
func WriteBackupZIP(destination, attachmentDirectory, manifest string) error {
	return writeFileZIP(destination, attachmentDirectory, manifest, backupFiles)
}

func writeFileZIP(destination, attachmentDirectory, manifest string, collect func([]byte) (zipFiles, error)) (err error) {
	if len(manifest) > maxBackupManifest {
		return errors.New("archive_manifest_too_large")
	}
	files, err := collect([]byte(manifest))
	if err != nil {
		return err
	}
	disk, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := disk.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			_ = os.Remove(destination)
		}
	}()
	output := zip.NewWriter(disk)
	header, err := output.Create(backupManifestName)
	if err != nil {
		return err
	}
	if _, err := io.WriteString(header, manifest); err != nil {
		return err
	}
	if len(files) != 0 {
		root, err := os.OpenRoot(attachmentDirectory)
		if err != nil {
			return err
		}
		defer root.Close()
		for name, size := range files {
			if err := writeBackupAttachment(output, root, name, size); err != nil {
				return err
			}
		}
	}
	return output.Close()
}

func writeBackupAttachment(output *zip.Writer, root *os.Root, name string, size int64) error {
	info, err := root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return errors.New("missing_or_changed_backup_attachment")
	}
	source, err := root.Open(name)
	if err != nil {
		return err
	}
	defer source.Close()
	entry, err := output.CreateHeader(&zip.FileHeader{Name: backupFilePrefix + name, Method: zip.Store})
	if err != nil {
		return err
	}
	return copyBackupFile(entry, source, size)
}

// ReadBackupZIP checks the manifest and streams exactly its attachments into
// an app-owned staging directory. Files created by a failed restore are removed.
func ReadBackupZIP(source, stagingDirectory string) (string, error) {
	return readFileZIP(source, stagingDirectory, backupFiles)
}

func readFileZIP(source, stagingDirectory string, collect func([]byte) (zipFiles, error)) (_ string, err error) {
	archive, err := zip.OpenReader(source)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	if len(archive.File) > maxBackupEntries+1 {
		return "", errors.New("too_many_backup_attachments")
	}
	var manifest []byte
	entries := make(map[string]*zip.File)
	for _, entry := range archive.File {
		if !entry.Mode().IsRegular() {
			return "", errors.New("invalid_backup_entry")
		}
		if entry.Name == backupManifestName && manifest == nil {
			manifest, err = readBackupManifest(entry)
			if err != nil {
				return "", err
			}
			continue
		}
		name, prefixed := strings.CutPrefix(entry.Name, backupFilePrefix)
		if !prefixed || !isBackupFileName(name) || entries[name] != nil ||
			entry.Method != zip.Store || entry.CompressedSize64 != entry.UncompressedSize64 {
			return "", errors.New("invalid_backup_entry")
		}
		entries[name] = entry
	}
	files, err := collect(manifest)
	if err != nil {
		return "", err
	}
	if len(entries) != len(files) {
		return "", errors.New("backup_attachment_mismatch")
	}
	for name, size := range files {
		if entries[name] == nil || entries[name].UncompressedSize64 != uint64(size) {
			return "", errors.New("backup_attachment_mismatch")
		}
	}
	root, err := os.OpenRoot(stagingDirectory)
	if err != nil {
		return "", err
	}
	defer root.Close()
	created := make([]string, 0, len(entries))
	defer func() {
		if err != nil {
			for _, name := range created {
				_ = root.Remove(name)
			}
		}
	}()
	for name, entry := range entries {
		input, err := entry.Open()
		if err != nil {
			return "", err
		}
		output, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			input.Close()
			return "", err
		}
		created = append(created, name)
		copyErr := copyBackupFile(output, input, files[name])
		input.Close()
		closeErr := output.Close()
		if copyErr != nil || closeErr != nil {
			return "", errors.Join(copyErr, closeErr)
		}
	}
	return string(manifest), nil
}

func readBackupManifest(entry *zip.File) ([]byte, error) {
	if entry.UncompressedSize64 > maxBackupManifest {
		return nil, errors.New("backup_manifest_too_large")
	}
	input, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer input.Close()
	data, err := io.ReadAll(io.LimitReader(input, maxBackupManifest+1))
	if err != nil || uint64(len(data)) != entry.UncompressedSize64 || len(data) == 0 {
		return nil, errors.New("invalid_backup_manifest")
	}
	return data, nil
}

func copyBackupFile(destination io.Writer, source io.Reader, size int64) error {
	if _, err := io.CopyN(destination, source, size); err != nil {
		return err
	}
	// Read through EOF so zip verifies the entry checksum, including empty files.
	var extra [1]byte
	if _, err := io.ReadFull(source, extra[:]); err != io.EOF {
		if err == nil {
			err = errors.New("backup_attachment_size_changed")
		}
		return err
	}
	return nil
}
