import Foundation

@main @MainActor
struct ChatGPTSignInPersistenceTests {
    static func main() throws {
        let suite = "com.pendingname.aauv.sign-in-persistence-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // These are the actual pre-write guards used by the login view. Empty
        // defaults must not cancel a first sign-in, while real changes must.
        let values: [String?] = [nil, "", "revision-A", "revision-B"]
        for before in values {
            for after in values {
                defaults.set(before, forKey: APIKey.revisionKey)
                let snapshot = ChatGPTSignInRevision(defaults: defaults)
                defaults.set(after, forKey: APIKey.revisionKey)
                let expected = (before ?? "") == (after ?? "")
                do {
                    try snapshot.validate(defaults: defaults)
                    precondition(expected, "A real configuration change allowed stale credentials to be saved")
                } catch is ChatGPTSignInRevision.Changed {
                    precondition(!expected, "An empty default incorrectly rejected a sign-in")
                }
            }
        }

        var credentials = OAuthCredentials(flow: .chatgptPlan, accessToken: "SYNTHETIC_SECRET_ACCESS",
            refreshToken: "SYNTHETIC_SECRET_REFRESH", idToken: "SYNTHETIC_SECRET_ID",
            clientID: "oaiapp_synthetic-valid", expiresAt: 2_000_000_000,
            verifiedSubject: "SYNTHETIC_SECRET_SUBJECT")
        let endpoint = try APIKey.nativeChatGPTSaveEndpoint(credentials)
        precondition(endpoint.absoluteString == "https://aauv.invalid/chatgpt/oaiapp_synthetic-valid")
        // The real failure had a valid prefix, 32 UTF-8 bytes and no rejected
        // characters. Exercise every allowed suffix byte in that exact shape,
        // through both validation and the actual pre-write address builder.
        for scalar in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".unicodeScalars {
            let id = "oaiapp_" + String(repeating: String(scalar), count: 25)
            credentials.clientID = id
            precondition(id.utf8.count == 32 && APIKey.isNativeRegistrationID(id))
            let actual = try APIKey.nativeChatGPTSaveEndpoint(credentials)
            let legacy = URL(string: "https://aauv.invalid/chatgpt/")!.appending(path: id)
            precondition(actual == legacy && actual.absoluteString == "https://aauv.invalid/chatgpt/" + id)
        }
        for count in [1, 249] {
            credentials.clientID = "oaiapp_" + String(repeating: "A", count: count)
            precondition(APIKey.isNativeRegistrationID(credentials.clientID!))
            _ = try APIKey.nativeChatGPTSaveEndpoint(credentials)
        }
        for id in ["oaiapp_bad.name", "oaiapp_bad/path", "oaiapp_", "dynamic_agent_client"] {
            credentials.clientID = id
            do {
                _ = try APIKey.nativeChatGPTSaveEndpoint(credentials)
                preconditionFailure("An invalid registration bypassed the pre-write validator")
            } catch let error as APIKey.NativeChatGPTSaveError {
                ChatGPTSignInFeedback.record(error, stage: .save, defaults: defaults)
                let saved = defaults.dictionary(forKey: ChatGPTSignInFeedback.diagnosticKey)!
                precondition(saved["category"] as? String == "registration_format")
                if id == "oaiapp_bad.name" {
                    precondition(saved["rejectedScalarValues"] as? [Int] == [46])
                }
                let encoded = String(decoding: try JSONSerialization.data(withJSONObject: saved), as: UTF8.self)
                precondition(!encoded.contains("SYNTHETIC_SECRET") && !encoded.contains(id))
            }
        }
        for invalid in ["oaiapp_A/B", "oaiapp_A?B", "oaiapp_A#B", "oaiapp_A%2FB", "oaiapp_中文", "oaiapp_A\n",
                        "oaiapp_" + String(repeating: "A", count: 250)] {
            precondition(!APIKey.isNativeRegistrationID(invalid), "Unsafe or oversized identifiers must remain blocked")
        }
        credentials.clientID = "oaiapp_synthetic-valid"
        credentials.verifiedSubject = nil
        do {
            _ = try APIKey.nativeChatGPTSaveEndpoint(credentials)
            preconditionFailure("Unverified credentials were accepted as a native sign-in")
        } catch APIKey.NativeChatGPTSaveError.identity {}

        for domain in [NSCocoaErrorDomain, NSURLErrorDomain, "SYNTHETIC_SECRET_DOMAIN"] {
            let error = NSError(domain: domain, code: 514, userInfo: [
                NSLocalizedDescriptionKey: "SYNTHETIC_SECRET_DESCRIPTION",
                NSURLErrorFailingURLStringErrorKey: "https://example.invalid/?token=SYNTHETIC_SECRET_URL"
            ])
            ChatGPTSignInFeedback.record(error, stage: .save, defaults: defaults)
            let saved = defaults.dictionary(forKey: ChatGPTSignInFeedback.diagnosticKey)!
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: saved), as: UTF8.self)
            precondition(!encoded.contains("SYNTHETIC_SECRET"))
            precondition(!ChatGPTSignInFeedback.failureMessage(stage: .save, error: error).contains("SYNTHETIC_SECRET"))
        }
        print("Sign-in pre-write guards passed empty/default and real-change cases; invalid or unverified registrations stayed blocked; saved diagnostics excluded identifiers, tokens, raw descriptions and URLs. No Keychain write or network request was used.")
    }
}
