package aauvcore

import (
	"encoding/json"
	"errors"
)

// WriteReplicaZIP streams an attachment-bearing sync record into a CKAsset.
func WriteReplicaZIP(destination, attachmentDirectory, manifest string) error {
	return writeFileZIP(destination, attachmentDirectory, manifest, replicaArchiveFiles)
}

// ReadReplicaZIP extracts and checks the attachment bytes for a sync record.
func ReadReplicaZIP(source, stagingDirectory string) (string, error) {
	return readFileZIP(source, stagingDirectory, replicaArchiveFiles)
}

func replicaArchiveFiles(manifest []byte) (zipFiles, error) {
	var record replicaRecord
	if err := json.Unmarshal(manifest, &record); err != nil {
		return nil, err
	}
	if record.Kind != "conversation" && record.Kind != "message" {
		return nil, errors.New("invalid_replica_archive_kind")
	}
	var payload struct {
		Attachments []backupAttachment `json:"attachments"`
	}
	if err := json.Unmarshal([]byte(record.Payload), &payload); err != nil {
		return nil, err
	}
	files := make(zipFiles)
	if err := files.add(payload.Attachments); err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, errors.New("replica_archive_missing_attachments")
	}
	return files, nil
}
