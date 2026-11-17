package aauvcore

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBackupZIPRoundTripAndChecksum(t *testing.T) {
	const name = "7FB0EF1E-0AB4-4116-95C1-ACBF3F660214"
	const empty = "0AEB88EC-AF9C-4F82-BC51-6C89018E0134"
	const manifest = `{"version":2,"conversations":[{"attachments":[{"fileName":"` + empty +
		`","size":0}],"messages":[{"attachments":[{"fileName":"` + name + `","size":3}]}]}]}`
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, name), []byte{0, 42, 255}, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, empty), nil, 0600); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(t.TempDir(), "test.aauvbackup")
	if err := WriteBackupZIP(archive, root, manifest); err != nil {
		t.Fatal(err)
	}
	out := t.TempDir()
	got, err := ReadBackupZIP(archive, out)
	if err != nil || got != manifest {
		t.Fatalf("restore: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(out, name))
	if err != nil || !bytes.Equal(data, []byte{0, 42, 255}) {
		t.Fatalf("incorrect attachment: %v", err)
	}
	if info, err := os.Stat(filepath.Join(out, empty)); err != nil || info.Size() != 0 {
		t.Fatalf("empty attachment missing: %v", err)
	}

	reader, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatal(err)
	}
	var offset int64
	for _, entry := range reader.File {
		if entry.Name == backupFilePrefix+name {
			offset, err = entry.DataOffset()
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	reader.Close()
	if offset <= 0 {
		t.Fatal("attachment offset missing")
	}
	file, err := os.OpenFile(archive, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.WriteAt([]byte{99}, offset); err != nil {
		t.Fatal(err)
	}
	file.Close()
	out = t.TempDir()
	if _, err := ReadBackupZIP(archive, out); err == nil {
		t.Fatal("corrupted attachment accepted")
	}
	if entries, err := os.ReadDir(out); err != nil || len(entries) != 0 {
		t.Fatal("failed restore left staged files")
	}
}

func TestRestoreBackupCommitsConfigurationMarkerWithConversations(t *testing.T) {
	db, err := OpenLocalStore(filepath.Join(t.TempDir(), "restore.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	const id = "7FB0EF1E-0AB4-4116-95C1-ACBF3F660214"
	const occupied = `[{"id":"existing","messages":[]}]`
	if err := db.Insert(occupied, false); err != nil {
		t.Fatal(err)
	}
	const duplicate = `[{"id":"existing","messages":[]},{"id":"new","messages":[]}]`
	const prompt = `{"prompt":"restored","skills":""}`
	if err := db.RestoreCopiesForConfigurationImport(id, duplicate, "[]", prompt); err == nil {
		t.Fatal("expected duplicate conversation to abort restore")
	}
	committed, err := db.ConfigurationImportCommitted(id)
	if err != nil || committed {
		t.Fatalf("failed restore wrote marker: %v", err)
	}
	data, err := db.Snapshot()
	if err != nil || strings.Contains(data, `"new"`) {
		t.Fatalf("failed restore wrote conversation: %v", err)
	}
	const valid = `[{"id":"new","messages":[]}]`
	if err := db.RestoreCopiesForConfigurationImport(id, valid, "[]", prompt); err != nil {
		t.Fatal(err)
	}
	committed, err = db.ConfigurationImportCommitted(id)
	if err != nil || !committed {
		t.Fatalf("completed restore lost marker: %v", err)
	}
	data, err = db.Snapshot()
	if err != nil || !strings.Contains(data, `"new"`) {
		t.Fatalf("completed restore lost conversation: %v", err)
	}
	instructions, err := db.Instructions()
	if err != nil || instructions != prompt {
		t.Fatalf("completed restore lost shared prompt: %v", err)
	}
}

func TestBackupZIPRejectsUnexpectedPaths(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "test.aauvbackup")
	disk, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	output := zip.NewWriter(disk)
	for _, name := range []string{backupManifestName, "attachments/../escaped"} {
		entry, err := output.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(`{"version":2,"conversations":[]}`)); err != nil {
			t.Fatal(err)
		}
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	disk.Close()
	stage := t.TempDir()
	if _, err := ReadBackupZIP(archive, stage); err == nil {
		t.Fatal("unexpected ZIP path accepted")
	}
	if entries, err := os.ReadDir(stage); err != nil || len(entries) != 0 {
		t.Fatal("untrusted archive wrote files")
	}
}
