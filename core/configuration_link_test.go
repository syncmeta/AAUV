package aauvcore

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

func TestConfigurationLinkInteroperability(t *testing.T) {
	// Produced by the zlib level 9 encoder previously used by the Apple app.
	const oldLink = "aauv://import?v=2&c=zlib#eNpFyzEOwyAMQNG7eE6K2pE79BC0mMQK2Ig4KCjq3etOXb_evyBJK0HBQwhHn9_CiRaYoGPbSRj8YwLkWIX4h1bVunvn8AylZrwR95Apun63p0jEbCjRqUdDK1kW4ifqKtH6a8hmccPxR7NwHvD5AnyLLrc"
	const oldDocument = `{"format":"aauv-config","version":2,"endpoint":"https://example.invalid/v1","model":"fixture","loginMethod":"byok","key":"fixture-only"}`
	for _, link := range []string{
		oldLink,
		"\n" + oldDocument + " ",
		"aauv1:" + base64.StdEncoding.EncodeToString([]byte(oldDocument)),
	} {
		data, err := DecodeConfigurationLink(link)
		if err != nil || string(data) != oldDocument {
			t.Fatalf("could not read an existing configuration format: %v", err)
		}
	}
	for _, test := range []struct {
		payload     string
		compression string
	}{
		{"{}", "none"},
		{`{"skills":"` + strings.Repeat("常用指令", 1000) + `"}`, "zlib"},
		{"{" + strings.Repeat("a", ConfigurationLinkMaximumBytes-2) + "}", "zlib"},
	} {
		link, err := EncodeConfigurationLink([]byte(test.payload))
		if err != nil || !strings.HasPrefix(link, "aauv://import?v=2&c="+test.compression+"#") {
			t.Fatalf("unexpected envelope for %d bytes: %v", len(test.payload), err)
		}
		data, err := DecodeConfigurationLink(link)
		if err != nil || string(data) != test.payload {
			t.Fatalf("round trip failed for %d bytes: %v", len(test.payload), err)
		}
	}
}

func TestConfigurationLinkRejectsBadEnvelopesAndOversizeData(t *testing.T) {
	for _, invalid := range []string{
		"aauv://import?v=2&v=2&c=none#e30",
		"aauv://import?v=999&c=none#e30",
		"aauv://import?v=2&c=unknown#e30",
		"aauv://import?v=2&&c=none#e30",
		"aauv://user@import?v=2&c=none#e30",
		"aauv://import:80?v=2&c=none#e30",
		"aauv://import/path?v=2&c=none#e30",
		"aauv://import?v=2&c=none#e30%0A",
		"aauv://import?v=2&c=none#e30=",
		"aauv://import?v=2&c=zlib#e30",
		"aauv1:e3\r\n0=",
	} {
		if _, err := DecodeConfigurationLink(invalid); !errors.Is(err, errInvalidConfigurationLink) {
			t.Errorf("accepted malformed envelope %q: %v", invalid, err)
		}
	}
	large := []byte("{" + strings.Repeat("a", ConfigurationLinkMaximumBytes) + "}")
	if _, err := EncodeConfigurationLink(large); !errors.Is(err, errConfigurationTooLarge) {
		t.Errorf("oversize encode: %v", err)
	}
	var packed bytes.Buffer
	writer := zlib.NewWriter(&packed)
	if _, err := writer.Write(large); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{
		string(large),
		"aauv1:" + base64.StdEncoding.EncodeToString(large),
		"aauv://import?v=2&c=none#" + base64.RawURLEncoding.EncodeToString(large),
		"aauv://import?v=2&c=zlib#" + base64.RawURLEncoding.EncodeToString(packed.Bytes()),
	} {
		if _, err := DecodeConfigurationLink(input); !errors.Is(err, errConfigurationTooLarge) {
			t.Errorf("oversize decode: %v", err)
		}
	}
}
