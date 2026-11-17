package aauvcore

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

const publicPrefsSeed = "B0D50E1E-D74B-4D28-BE29-B60C88337001"
const publicPrefsCatalog = `[{"name":"Synthetic BYOK","loginMethod":"byok","endpoint":"https://api.example.invalid/v1","apiProtocol":"responses","models":[{"id":"model-one","name":"Model One"}]}]`

func publicPrefsOpen(t *testing.T, path string) *LocalStore {
	t.Helper()
	s, err := OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}
func publicPrefsLocal(name, catalog string) string {
	fields := map[string]json.RawMessage{}
	if name != "" {
		data, _ := json.Marshal(map[string]string{"name": name, "avatarSeed": publicPrefsSeed})
		fields["profile"] = data
	}
	if catalog != "" {
		fields["modelServices"] = json.RawMessage(catalog)
	}
	data, _ := json.Marshal(fields)
	return string(data)
}
func publicPrefsReconcile(t *testing.T, s *LocalStore, local string) string {
	t.Helper()
	result, err := s.ReconcilePublicPreferences(local)
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func publicPrefsProjection(t *testing.T, s *LocalStore) string {
	t.Helper()
	text, err := s.PublicPreferences()
	if err != nil {
		t.Fatal(err)
	}
	return text
}
func publicPrefsPending(t *testing.T, s *LocalStore) []replicaRecord {
	t.Helper()
	text, err := s.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	var rows []replicaRecord
	if err = json.Unmarshal([]byte(text), &rows); err != nil {
		t.Fatal(err)
	}
	return rows
}
func publicPrefsACK(t *testing.T, s *LocalStore) {
	t.Helper()
	for _, row := range publicPrefsPending(t, s) {
		if err := s.AcknowledgeReplica(row.Name, row.Revision); err != nil {
			t.Fatal(err)
		}
	}
}
func publicPrefsApply(t *testing.T, s *LocalStore, record replicaRecord) {
	t.Helper()
	text, _ := json.Marshal(record)
	if err := s.ApplyReplica(string(text)); err != nil {
		t.Fatal(err)
	}
}
func publicPrefsProfileRecord(t *testing.T, name, revision string) replicaRecord {
	t.Helper()
	state, err := decodePublicPreferenceState(publicPrefsLocal(name, ""))
	if err != nil {
		t.Fatal(err)
	}
	return replicaRecord{Name: publicProfileRecord, Kind: publicProfileKind, Revision: revision, Payload: string(state.Profile)}
}
func publicPrefsRaw(t *testing.T, s *LocalStore) string {
	t.Helper()
	rows, err := s.run("SELECT json_array(name,kind,conversation,revision,payload,pending) FROM replica ORDER BY name")
	if err != nil {
		t.Fatal(err)
	}
	mirror, err := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesMirror)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal([]any{rows, mirror})
	return string(data)
}

func TestPublicPreferencesSeedAndIndependentLWW(t *testing.T) {
	a := publicPrefsOpen(t, filepath.Join(t.TempDir(), "a.sqlite"))
	b := publicPrefsOpen(t, filepath.Join(t.TempDir(), "b.sqlite"))
	initial := publicPrefsLocal("Original", publicPrefsCatalog)
	projection := publicPrefsReconcile(t, a, initial)
	if !strings.Contains(projection, `"name":"Original"`) {
		t.Fatal("profile projection missing")
	}
	seeded := publicPrefsPending(t, a)
	if len(seeded) != 2 {
		t.Fatal("two independent seeds required")
	}
	for _, row := range seeded {
		if row.Revision != "0000000000000000001" {
			t.Fatal("seed outranks existing cloud state")
		}
		publicPrefsApply(t, b, row)
	}
	publicPrefsACK(t, a)
	fallback := publicPrefsLocal("Fresh random fallback", `[]`)
	if got := publicPrefsReconcile(t, b, fallback); got != projection || len(publicPrefsPending(t, b)) != 0 {
		t.Fatal("fallback replaced remote state")
	}
	if err := b.MarkPublicPreferencesPublished(projection); err != nil {
		t.Fatal(err)
	}
	changedProfile := publicPrefsReconcile(t, b, publicPrefsLocal("Edited B", publicPrefsCatalog))
	profilePending := publicPrefsPending(t, b)
	if len(profilePending) != 1 || profilePending[0].Name != publicProfileRecord {
		t.Fatal("profile edit staged catalog")
	}
	catalog := strings.ReplaceAll(publicPrefsCatalog, "model-one", "model-two")
	publicPrefsReconcile(t, a, publicPrefsLocal("Original", catalog))
	catalogPending := publicPrefsPending(t, a)
	if len(catalogPending) != 1 || catalogPending[0].Name != publicModelServicesRecord {
		t.Fatal("catalog edit staged profile")
	}
	publicPrefsApply(t, a, profilePending[0])
	publicPrefsApply(t, b, catalogPending[0])
	publicPrefsACK(t, a)
	publicPrefsACK(t, b)
	finalA, finalB := publicPrefsProjection(t, a), publicPrefsProjection(t, b)
	if finalA != finalB || !strings.Contains(finalA, "Edited B") || !strings.Contains(finalA, "model-two") {
		t.Fatal("independent fields did not converge")
	}
	if err := a.MarkPublicPreferencesPublished(finalA); err != nil {
		t.Fatal(err)
	}
	if err := b.MarkPublicPreferencesPublished(finalB); err != nil {
		t.Fatal(err)
	}
	publicPrefsReconcile(t, b, finalB)
	if len(publicPrefsPending(t, b)) != 0 || changedProfile == finalB {
		t.Fatal("remote publication echoed or catalog update lost")
	}
}

func TestPublicPreferencesExistingRecordOnlySeedsAbsentField(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "s.sqlite"))
	publicPrefsApply(t, s, publicPrefsProfileRecord(t, "Cloud", "0000000000000000042"))
	text := publicPrefsReconcile(t, s, publicPrefsLocal("Device random", publicPrefsCatalog))
	rows := publicPrefsPending(t, s)
	if !strings.Contains(text, `"name":"Cloud"`) || len(rows) != 1 || rows[0].Name != publicModelServicesRecord || rows[0].Revision != "0000000000000000001" {
		t.Fatal("initial mirror overwrote present record or failed absent seed")
	}
	before := publicPrefsRaw(t, s)
	publicPrefsReconcile(t, s, publicPrefsLocal("Device random", publicPrefsCatalog))
	if publicPrefsRaw(t, s) != before {
		t.Fatal("unchanged fallback changed remote or seed revision")
	}
}

func TestPublicPreferencesMissingNullAndExplicitEmptyCatalog(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "s.sqlite"))
	initial := publicPrefsReconcile(t, s, publicPrefsLocal("Profile", publicPrefsCatalog))
	publicPrefsACK(t, s)
	if got := publicPrefsReconcile(t, s, `{"profile":null,"modelServices":null}`); got != initial || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("null deleted public state")
	}
	if err := s.MarkPublicPreferencesPublished(initial); err != nil {
		t.Fatal(err)
	}
	publicPrefsReconcile(t, s, publicPrefsLocal("Profile", ""))
	if len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("absent catalog staged a clear")
	}
	cleared := publicPrefsReconcile(t, s, publicPrefsLocal("Profile", `[]`))
	rows := publicPrefsPending(t, s)
	if len(rows) != 1 || rows[0].Name != publicModelServicesRecord || rows[0].Payload != "[]" || !strings.Contains(cleared, `"modelServices":[]`) {
		t.Fatal("explicit catalog clear lost")
	}
	if err := s.MarkPublicPreferencesPublished(`{}`); err != errPublicPreferencesChanged {
		t.Fatal("incomplete publication marked current")
	}
	publicPrefsACK(t, s)
	if got := publicPrefsReconcile(t, s, `{}`); got != cleared || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("missing fields resurrected catalog or cleared profile")
	}
}

func TestPublicPreferencesCrashRecoveryAndPublicationCAS(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.sqlite")
	s := publicPrefsOpen(t, path)
	oldCache := publicPrefsReconcile(t, s, publicPrefsLocal("Old cache", publicPrefsCatalog))
	publicPrefsACK(t, s)
	publicPrefsApply(t, s, publicPrefsProfileRecord(t, "Remote", "0000000000000000100"))
	remote := publicPrefsReconcile(t, s, oldCache)
	if !strings.Contains(remote, `"name":"Remote"`) || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("old cache re-uploaded over remote")
	}
	s.Close()
	s = publicPrefsOpen(t, path)
	if got := publicPrefsReconcile(t, s, oldCache); got != remote || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("restart lost mirror publication intent")
	}
	before := publicPrefsRaw(t, s)
	// Defaults written, crash before Mark: compare semantic current Core first.
	if got := publicPrefsReconcile(t, s, remote); got != remote || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("cache-written-before-mark echoed")
	}
	rows, _ := s.run("SELECT revision FROM replica WHERE name=?", publicProfileRecord)
	if len(rows) != 1 || rows[0] != "0000000000000000100" {
		t.Fatal("publication retry bumped clock")
	}
	publicPrefsApply(t, s, publicPrefsProfileRecord(t, "Newer remote", "0000000000000000101"))
	mirrorBefore, _ := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesMirror)
	if err := s.MarkPublicPreferencesPublished(remote); err != errPublicPreferencesChanged {
		t.Fatal("stale publication accepted")
	}
	mirrorAfter, _ := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesMirror)
	if strings.Join(mirrorBefore, "") != strings.Join(mirrorAfter, "") {
		t.Fatal("failed mark changed mirror")
	}
	current := publicPrefsProjection(t, s)
	if err := s.MarkPublicPreferencesPublished(current); err != nil {
		t.Fatal(err)
	}
	publicPrefsReconcile(t, s, current)
	if len(publicPrefsPending(t, s)) != 0 || before == publicPrefsRaw(t, s) {
		t.Fatal("new projection lost or unexpectedly echoed")
	}
}

func TestPublicPreferencesCanonicalPublicationAndNoopMirror(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "s.sqlite"))
	initial := publicPrefsReconcile(t, s, publicPrefsLocal("Name", publicPrefsCatalog))
	publicPrefsACK(t, s)
	if err := s.exec(`CREATE TABLE public_mirror_updates(n INTEGER); CREATE TRIGGER public_mirror_watch AFTER UPDATE ON metadata WHEN new.key='public_preferences_mirror_v1' BEGIN INSERT INTO public_mirror_updates VALUES(1); END;`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		publicPrefsReconcile(t, s, initial)
		if err := s.MarkPublicPreferencesPublished(initial); err != nil {
			t.Fatal(err)
		}
	}
	rows, _ := s.run("SELECT count(*) FROM public_mirror_updates")
	if len(rows) != 1 || rows[0] != "0" {
		t.Fatal("same semantic mirror was rewritten")
	}
	raw := `{"avatarSeed":"` + publicPrefsSeed + `", "name":"  Remote name  "}`
	publicPrefsApply(t, s, replicaRecord{Name: publicProfileRecord, Kind: publicProfileKind, Revision: "0000000000000000123", Payload: raw})
	projection := publicPrefsReconcile(t, s, initial)
	publicPrefsReconcile(t, s, projection)
	if len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("canonical equal remote body echoed")
	}
	if err := s.MarkPublicPreferencesPublished(projection); err != nil {
		t.Fatal(err)
	}
	stored, _ := s.run("SELECT payload FROM replica WHERE name=?", publicProfileRecord)
	if len(stored) != 1 || stored[0] != raw {
		t.Fatal("semantic publication rewrote remote payload")
	}
}

func TestPublicPreferencesSecretAndMalformedInputAtomicRejection(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "s.sqlite"))
	publicPrefsReconcile(t, s, publicPrefsLocal("Safe", publicPrefsCatalog))
	publicPrefsACK(t, s)
	bad := map[string]string{
		"root credential": `{"credentials":{"key":"SYNTHETIC_SECRET"}}`,
		"profile secret":  `{"profile":{"name":"X","avatarSeed":"` + publicPrefsSeed + `","key":"SYNTHETIC_SECRET"}}`,
		"service OAuth":   `{"modelServices":[{"name":"X","loginMethod":"byok","endpoint":"https://example.invalid","oauth":{"accessToken":"SYNTHETIC_SECRET"}}]}`,
		"model key":       strings.Replace(publicPrefsLocal("Safe", publicPrefsCatalog), `"id":"model-one"`, `"key":"SYNTHETIC_SECRET","id":"model-one"`, 1),
		"case alias":      `{"Profile":{"name":"X","avatarSeed":"` + publicPrefsSeed + `"}}`,
		"duplicate key":   `{"profile":{"name":"X","name":"Y","avatarSeed":"` + publicPrefsSeed + `"}}`,
		"wrong avatar":    `{"profile":{"name":"X","avatarSeed":"invalid"}}`,
		"top null":        `null`,
		"trailing JSON":   `{} {}`,
	}
	for name, local := range bad {
		t.Run(name, func(t *testing.T) {
			before := publicPrefsRaw(t, s)
			if _, err := s.ReconcilePublicPreferences(local); err == nil {
				t.Fatal("unsafe input accepted")
			}
			if err := s.MarkPublicPreferencesPublished(local); err == nil {
				t.Fatal("unsafe publication accepted")
			}
			if publicPrefsRaw(t, s) != before {
				t.Fatal("invalid input changed state")
			}
		})
	}
	// The containing replica validator must reject stale secret payloads too.
	before := publicPrefsRaw(t, s)
	payload := `[{"name":"X","loginMethod":"byok","endpoint":"https://example.invalid","models":[{"id":"x","api_key":"SYNTHETIC_SECRET"}]}]`
	record := replicaRecord{Name: publicModelServicesRecord, Kind: publicModelServicesKind, Revision: "0000000000000000001", Payload: payload}
	text, _ := json.Marshal(record)
	if _, err := s.ApplyReplicaChecked(string(text)); err == nil {
		t.Fatal("stale unsafe remote accepted")
	}
	if publicPrefsRaw(t, s) != before {
		t.Fatal("unsafe remote changed mirror/outbox")
	}
}

func TestPublicPreferencesCatalogValidationAndBounds(t *testing.T) {
	validCID := "oaiapp_Synthetic-account_1"
	valid := `[{"name":"Plan","loginMethod":"chatgpt","endpoint":"https://api.openai.com/v1","chatGPTClientID":"` + validCID + `","models":[{"id":" x "},{"id":"x","name":"duplicate"}]}]`
	canonical, err := canonicalPublicPreferencePayload(publicModelServicesKind, []byte(valid))
	if err != nil || !strings.Contains(string(canonical), validCID) || strings.Count(string(canonical), `"id":"x"`) != 1 {
		t.Fatal("native CID or model canonicalization failed", err)
	}
	for _, endpoint := range []string{"https://user:secret@example.invalid/v1", "https://example.invalid/v1?key=x", "https://example.invalid/v1?", "https://example.invalid/v1#", "https://AAUV.INVALID./v1", "http://example.invalid/v1"} {
		data, _ := json.Marshal([]map[string]any{{"name": "X", "loginMethod": "byok", "endpoint": endpoint}})
		if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, data); err == nil {
			t.Fatal("unsafe endpoint accepted")
		}
	}
	for _, endpoint := range []string{"http://localhost:1234/v1", "http://127.0.0.1:1234/v1", "http://[::1]:1234/v1", "https://EXAMPLE.invalid/v1/"} {
		if _, err := publicPreferenceEndpoint(endpoint); err != nil {
			t.Fatal("safe endpoint rejected", err)
		}
	}
	for _, cid := range []string{publicPrefsSeed, "oaiapp_", "oaiapp_非ASCII", "oaiapp_bad/path"} {
		if publicPreferenceNativeCID(cid) {
			t.Fatal("invalid native CID accepted")
		}
	}
	for _, raw := range []string{`null`, `[{"name":"X","loginMethod":"byok","endpoint":"https://a.invalid","models":[null]}]`, `[{"name":"X","loginMethod":"byok","endpoint":"https://a.invalid","models":{}}]`} {
		if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, []byte(raw)); err == nil {
			t.Fatal("invalid catalog accepted")
		}
	}
	service := json.RawMessage(`{"name":"X","loginMethod":"byok","endpoint":"https://a.invalid"}`)
	many := make([]json.RawMessage, 129)
	for i := range many {
		many[i] = service
	}
	data, _ := json.Marshal(many)
	if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, data); err == nil {
		t.Fatal("catalog count bound missing")
	}
	if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, []byte(strings.Repeat(" ", publicCatalogMaximumBytes+1))); err == nil {
		t.Fatal("catalog byte bound missing")
	}
	for _, record := range []replicaRecord{
		{Name: "wrong", Kind: publicProfileKind, Payload: `{"name":"X","avatarSeed":"` + publicPrefsSeed + `"}`},
		{Name: publicModelServicesRecord, Kind: publicModelServicesKind, Conversation: "foreign", Payload: "[]"},
		{Name: publicProfileRecord, Kind: publicModelServicesKind, Payload: "[]"},
	} {
		if validatePublicPreferenceRecord(record) == nil {
			t.Fatal("invalid public record accepted")
		}
	}
}

func TestPublicPreferencesUnpublishedSeedYieldsToExistingCloudSeed(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "seed.sqlite"))
	fallback := publicPrefsLocal("ZZZ new device random", publicPrefsCatalog)
	publicPrefsReconcile(t, s, fallback)
	profile := publicPrefsProfileRecord(t, "AAA existing cloud", "0000000000000000001")
	publicPrefsApply(t, s, profile)
	publicPrefsApply(t, s, replicaRecord{Name: publicModelServicesRecord, Kind: publicModelServicesKind, Revision: "0000000000000000001", Payload: "[]"})
	projection := publicPrefsReconcile(t, s, fallback)
	if !strings.Contains(projection, "AAA existing cloud") || !strings.Contains(projection, `"modelServices":[]`) || len(publicPrefsPending(t, s)) != 0 {
		t.Fatal("unpublished lexically larger fallback defeated existing cloud seed")
	}
	if err := s.MarkPublicPreferencesPublished(projection); err != nil {
		t.Fatal(err)
	}
	// Once the local seed was acknowledged/received, ordinary LWW tie ordering
	// is restored rather than treating every later seed as authoritative.
	lower := publicPrefsProfileRecord(t, "000 older lexical seed", "0000000000000000001")
	publicPrefsApply(t, s, lower)
	if got := publicPrefsProjection(t, s); got != projection {
		t.Fatal("acknowledged seed skipped normal LWW ordering")
	}
}

func TestPublicPreferencesInvalidSecondFieldRollsBackFirstAndMirror(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "atomic.sqlite"))
	publicPrefsReconcile(t, s, publicPrefsLocal("Old", publicPrefsCatalog))
	publicPrefsACK(t, s)
	before := publicPrefsRaw(t, s)
	local := publicPrefsLocal("Valid new profile", `[{"name":"Bad","loginMethod":"byok","endpoint":"https://example.invalid","key":"SYNTHETIC_SECRET"}]`)
	if _, err := s.ReconcilePublicPreferences(local); err == nil {
		t.Fatal("invalid catalog accepted after valid profile")
	}
	if got := publicPrefsRaw(t, s); got != before {
		t.Fatal("failed combined validation changed first field or mirror")
	}
}

func TestPublicPreferencesCombiningDisplayNamesDoNotUseRuneLimits(t *testing.T) {
	// 45 e+combining-accent graphemes are 90 runes. Swift permits this name.
	name := strings.Repeat("e\u0301", 45)
	modelName := strings.Repeat("e\u0301", 140)
	profile, _ := json.Marshal(map[string]string{"name": name, "avatarSeed": publicPrefsSeed})
	if _, err := canonicalPublicPreferencePayload(publicProfileKind, profile); err != nil {
		t.Fatal("Core rejected a Swift-valid combining profile name", err)
	}
	services, _ := json.Marshal([]map[string]any{{
		"name": name, "loginMethod": "byok", "endpoint": "https://example.invalid/v1",
		"models": []map[string]string{{"id": "model", "name": modelName}},
	}})
	if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, services); err != nil {
		t.Fatal("Core rejected Swift-valid combining catalog display names", err)
	}
	tooLongID, _ := json.Marshal([]map[string]any{{
		"name": "Name", "loginMethod": "byok", "endpoint": "https://example.invalid/v1",
		"models": []map[string]string{{"id": strings.Repeat("x", 513)}},
	}})
	if _, err := canonicalPublicPreferencePayload(publicModelServicesKind, tooLongID); err == nil {
		t.Fatal("UTF-8 byte bound for model ID was relaxed")
	}
}

func TestPublicPreferencesPublishedBUnmarkedRemoteCReopen(t *testing.T) {
	for _, retryPrepare := range []bool{false, true} {
		name := "before_mark"
		if retryPrepare {
			name = "prepare_C_before_cache_write"
		}
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "publication.sqlite")
			writer := publicPrefsOpen(t, path)
			remote := publicPrefsOpen(t, path)
			cacheA := publicPrefsReconcile(t, writer, publicPrefsLocal("Cache A", publicPrefsCatalog))
			if err := writer.MarkPublicPreferencesPublished(cacheA); err != nil {
				t.Fatal(err)
			}
			publicPrefsACK(t, writer)
			publicPrefsApply(t, remote, publicPrefsProfileRecord(t, "Remote B", "0000000000000000200"))
			cacheB := publicPrefsReconcile(t, writer, cacheA)
			if !strings.Contains(cacheB, `"name":"Remote B"`) {
				t.Fatal("B was not offered for publication")
			}
			publicPrefsApply(t, remote, publicPrefsProfileRecord(t, "Remote C", "0000000000000000201"))
			pendingBefore, _ := writer.run("SELECT value FROM metadata WHERE key=?", publicPreferencesPending)
			_ = publicPrefsProjection(t, writer)
			pendingAfter, _ := writer.run("SELECT value FROM metadata WHERE key=?", publicPreferencesPending)
			if strings.Join(pendingBefore, "") != strings.Join(pendingAfter, "") {
				t.Fatal("read-only PublicPreferences created a publication offer")
			}
			if retryPrepare {
				if err := writer.MarkPublicPreferencesPublished(cacheB); err != errPublicPreferencesChanged {
					t.Fatal("B incorrectly marked over C")
				}
				prepared, err := writer.PreparePublicPreferencesPublication()
				if err != nil || !strings.Contains(prepared, `"name":"Remote C"`) {
					t.Fatal("retry did not durably offer C", err)
				}
				// Exit after Prepare(C) but before writing C: defaults still B.
			}
			writer.Close()
			writer = publicPrefsOpen(t, path)
			projection := publicPrefsReconcile(t, writer, cacheB)
			if !strings.Contains(projection, `"name":"Remote C"`) || len(publicPrefsPending(t, writer)) != 0 {
				t.Fatal("unmarked B publication was misclassified as a local edit and overwrote remote C")
			}
			if err := writer.MarkPublicPreferencesPublished(projection); err != nil {
				t.Fatal(err)
			}
			rows, _ := writer.run("SELECT count(*) FROM metadata WHERE key=?", publicPreferencesPending)
			if len(rows) != 1 || rows[0] != "0" {
				t.Fatal("successful publication did not retire candidates")
			}
			// Once publication is complete, an intentional edit back to B
			// must no longer be suppressed by a historical candidate digest.
			publicPrefsReconcile(t, writer, cacheB)
			if len(publicPrefsPending(t, writer)) != 1 {
				t.Fatal("retired candidate suppressed a later real edit")
			}
		})
	}
}

func TestPublicPreferencesPartialPublicationMatchesCandidatesPerField(t *testing.T) {
	for _, first := range []string{"profile", "catalog"} {
		t.Run(first, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "partial.sqlite")
			writer := publicPrefsOpen(t, path)
			remote := publicPrefsOpen(t, path)
			cacheA := publicPrefsReconcile(t, writer, publicPrefsLocal("Profile A", publicPrefsCatalog))
			if err := writer.MarkPublicPreferencesPublished(cacheA); err != nil {
				t.Fatal(err)
			}
			publicPrefsACK(t, writer)
			publicPrefsApply(t, remote, publicPrefsProfileRecord(t, "Profile B", "0000000000000000500"))
			publicPrefsApply(t, remote, replicaRecord{Name: publicModelServicesRecord, Kind: publicModelServicesKind, Revision: "0000000000000000500", Payload: "[]"})
			publicPrefsReconcile(t, writer, cacheA)
			catalogC := strings.ReplaceAll(publicPrefsCatalog, "model-one", "model-C")
			publicPrefsApply(t, remote, publicPrefsProfileRecord(t, "Profile C", "0000000000000000501"))
			publicPrefsApply(t, remote, replicaRecord{Name: publicModelServicesRecord, Kind: publicModelServicesKind, Revision: "0000000000000000501", Payload: catalogC})
			mixed := publicPrefsLocal("Profile B", publicPrefsCatalog)
			if first == "catalog" {
				mixed = publicPrefsLocal("Profile A", "[]")
			}
			writer.Close()
			writer = publicPrefsOpen(t, path)
			projection := publicPrefsReconcile(t, writer, mixed)
			if !strings.Contains(projection, `"name":"Profile C"`) || !strings.Contains(projection, "model-C") || len(publicPrefsPending(t, writer)) != 0 {
				t.Fatal("partial publication was re-uploaded as a profile/catalog edit")
			}
		})
	}
}

func TestPublicPreferencesPublicationBoundFailsWithoutLosingOldOffers(t *testing.T) {
	s := publicPrefsOpen(t, filepath.Join(t.TempDir(), "bounded.sqlite"))
	cache := publicPrefsReconcile(t, s, publicPrefsLocal("Original", ""))
	if err := s.MarkPublicPreferencesPublished(cache); err != nil {
		t.Fatal(err)
	}
	publicPrefsACK(t, s)
	for i := 0; i < publicPublicationLimit; i++ {
		name := "Remote " + strings.Repeat("x", i+1)
		// Distinct increasing valid revision values, all below a local clock.
		revision := fmt.Sprintf("%019d", 1000+i)
		publicPrefsApply(t, s, publicPrefsProfileRecord(t, name, revision))
		if _, err := s.PreparePublicPreferencesPublication(); err != nil {
			t.Fatal(err)
		}
	}
	before, _ := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesPending)
	publicPrefsApply(t, s, publicPrefsProfileRecord(t, "Newest beyond limit", "0000000000000002000"))
	coreBefore := publicPrefsRaw(t, s)
	if _, err := s.PreparePublicPreferencesPublication(); err == nil {
		t.Fatal("publication candidate bound missing")
	}
	after, _ := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesPending)
	if strings.Join(before, "") != strings.Join(after, "") {
		t.Fatal("limit discarded an old offered value")
	}
	if _, err := s.ReconcilePublicPreferences(publicPrefsLocal("Actual new edit", "")); err == nil {
		t.Fatal("new intent unexpectedly committed without recoverable offer")
	}
	if publicPrefsRaw(t, s) != coreBefore {
		t.Fatal("publication limit failed to roll back local intent/mirror")
	}
}
