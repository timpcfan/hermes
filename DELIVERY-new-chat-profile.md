# New-chat profile routing repair

Base: `891a7cc`. Product fix: `0ebc0ae`. Regression/UI tests: `acfae77`, `2f65f82`.

## Change

`ConversationModel.ensureChatRuntime` now captures the resolved profile before sending `session.create`, then uses that same value when adopting the returned stored session. Assigning `sessionID`, or changing the picker while awaiting the response, no longer changes the row key and subsequent profile routing to the gateway's home.

The only production change is one local constant and its two uses. No backend protocol, shared style, list traversal, database migration, or existing session data is changed.

## Verification

- The executable regression extracts the actual Swift getter and full creation method. The same test rejects the base in six scenarios and passes all eight against the repair. It covers cross-profile creation in both directions, home-profile controls, default-profile cases, waiting drafts, and picker changes while create awaits its response.
- Full Swift package tests: 97 + 1,932 tests passed (2,029 total).
- Debug macOS and iOS Simulator application builds passed; application warning gates and source-path cross-checks were clean.
- iPhone UI integration: choose Research Buddy, send the first message, wait for Stop to disappear, confirm the mock closes a runtime, then send a second message. The final test passed in 26.189 seconds; each user message was stored exactly once under the same researcher session.
- Mac integration: used an isolated application identity and home directory, selected Research Buddy through the actual picker, sent the first message, reclaimed the runtime, and sent the second in the same window. Mock readback confirmed one researcher session and one copy of each user message. The UI showed the researcher badge and a Research Buddy reply.
- Added-line scans found no private credentials, private environment paths, dynamic eval, unsafe deserialization, or shell execution.
- An independent read-only reviewer found no blocking issue in the production repair and its logic regression. The reviewer correctly noted that the probe's resume collaborator is a stub; the separate real-app mock exercises above provide lifecycle evidence. Later commits add only tests and do not change the reviewed production repair.

Run the regression from the repository root:

```sh
python3 -m unittest discover -s Tools/mock-hermes/tests -p test_new_chat_profile.py -v
```

Run the UI test with `Tools/mock-hermes/backend.py --cross-profile` and select:
`HermesUITests/NewChatComposerUITests/testANewChatsChosenProfileSurvivesAReclaimedRuntime`.

## Limits and environment notes

The change has not been installed on a physical iPhone or the user's MacBook. The wider UI-test target has an existing `VoiceUITests.swift` AnyClass inference warning present in the base; the repair adds none.

Claude Code's tool smoke tests produced no tool invocations, so the main agent implemented the fix directly. The independent reviewer read skill files outside its requested directory scope, but reported no configuration or credential access. The local test mock and isolated Mac test app have been stopped; the dedicated simulator was shut down by XCTest.
