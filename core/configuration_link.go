package aauvcore

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"errors"
	"io"
	"net/url"
	"strings"
)

const ConfigurationLinkMaximumBytes = 1 << 20

var (
	errConfigurationTooLarge    = errors.New("configuration_too_large")
	errInvalidConfigurationLink = errors.New("invalid_configuration_link")
)

// EncodeConfigurationLink wraps a portable configuration document. It does not
// validate the document's settings or handle its credentials.
func EncodeConfigurationLink(document []byte) (string, error) {
	if len(document) > ConfigurationLinkMaximumBytes {
		return "", errConfigurationTooLarge
	}
	if len(document) == 0 {
		return "", errInvalidConfigurationLink
	}
	var compressed bytes.Buffer
	writer, err := zlib.NewWriterLevel(&compressed, zlib.BestCompression)
	if err != nil {
		return "", err
	}
	if _, err := writer.Write(document); err != nil {
		return "", err
	}
	if err := writer.Close(); err != nil {
		return "", err
	}
	compression := "none"
	if compressed.Len() < len(document) {
		compression = "zlib"
		document = compressed.Bytes()
	}
	return "aauv://import?v=2&c=" + compression + "#" + base64.RawURLEncoding.EncodeToString(document), nil
}

// DecodeConfigurationLink accepts version 2 links, legacy aauv1 links and raw
// configuration JSON pasted into the same field. The result is always bounded.
func DecodeConfigurationLink(input string) ([]byte, error) {
	input = strings.TrimSpace(input)
	if len(input) > 2*ConfigurationLinkMaximumBytes {
		return nil, errConfigurationTooLarge
	}
	if strings.HasPrefix(input, "{") {
		if len(input) > ConfigurationLinkMaximumBytes {
			return nil, errConfigurationTooLarge
		}
		return []byte(input), nil
	}
	if encoded, legacy := strings.CutPrefix(input, "aauv1:"); legacy {
		if strings.ContainsAny(encoded, "\r\n") {
			return nil, errInvalidConfigurationLink
		}
		return decodeConfigurationBase64(base64.StdEncoding, encoded)
	}
	link, err := url.Parse(input)
	if err != nil || link.Scheme != "aauv" || link.Host != "import" || link.Path != "" || link.User != nil ||
		link.Fragment == "" || strings.ContainsAny(link.Fragment, "\r\n") || strings.Count(link.RawQuery, "&") != 1 {
		return nil, errInvalidConfigurationLink
	}
	items, err := url.ParseQuery(link.RawQuery)
	if err != nil || len(items) != 2 || len(items["v"]) != 1 || items.Get("v") != "2" || len(items["c"]) != 1 {
		return nil, errInvalidConfigurationLink
	}
	switch items.Get("c") {
	case "none":
		return decodeConfigurationBase64(base64.RawURLEncoding, link.Fragment)
	case "zlib":
		payload, err := decodeConfigurationBase64(base64.RawURLEncoding, link.Fragment)
		if err != nil {
			return nil, err
		}
		return decompressConfiguration(payload)
	default:
		return nil, errInvalidConfigurationLink
	}
}

func decodeConfigurationBase64(encoding *base64.Encoding, input string) ([]byte, error) {
	decoded, err := encoding.DecodeString(input)
	if err != nil || len(decoded) == 0 {
		return nil, errInvalidConfigurationLink
	}
	if len(decoded) > ConfigurationLinkMaximumBytes {
		return nil, errConfigurationTooLarge
	}
	return decoded, nil
}

func decompressConfiguration(payload []byte) ([]byte, error) {
	compressed := bytes.NewReader(payload)
	reader, err := zlib.NewReader(compressed)
	if err != nil {
		return nil, errInvalidConfigurationLink
	}
	defer reader.Close()
	decoded, err := io.ReadAll(io.LimitReader(reader, ConfigurationLinkMaximumBytes+1))
	if len(decoded) > ConfigurationLinkMaximumBytes {
		return nil, errConfigurationTooLarge
	}
	if err != nil || len(decoded) == 0 || compressed.Len() != 0 {
		return nil, errInvalidConfigurationLink
	}
	return decoded, nil
}
