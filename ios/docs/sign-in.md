# Signing in, tokens, the account

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Account`, auth middleware, Keychain.

## Signing in (task 3.4)

- `Features/Account/`: `AuthSession` (an actor) signs in with an emailed code (`clientType: ios`) and refreshes the
  access token. The server revokes the whole token family when a rotated refresh token is reused, so refreshes run
  one at a time and there is exactly one session per run (`APIConfiguration.liveSession`); never build a second.
  Only a 400 or 401 from refresh signs out; offline or a server error keeps the tokens.
- `AuthMiddleware` adds `Authorization: Bearer` to every operation except the public ones (health, auth, generate),
  and on a 401 retries once with the session's fresh token. Use `APIConfiguration.liveSignedInClient()` for
  signed-in calls.
- Tokens live in the Keychain (`KeychainTokenStore`), one item per API host and port, so deployed tokens never go to
  a local server. Never log them or put them in UserDefaults. Keychain items survive a reinstall: UI tests pass
  `-auth.reset YES` to start signed out.
- The save UI test signs in with a fresh address each run and reads the code from `/__test/codes/latest`.
- Sign-in must be reachable on its own, not only inside a save (issue #129: after Sign out the only way in was the save
  flow, which creates a new plan and hides the account's existing one). `SignInModel` is plain sign-in: it asks for the
  email and code through the same `AuthSession`, then `onSignedIn` calls `PlanStore.load()`, which shows the account's
  most recent plan and never creates one; an account with no plan lands on "Set a goal". `SignInView` serves both models
  (`SignInFlowing`, `purpose: .save | .signIn`). `RootView` owns one sheet and offers it through the `requestSignIn`
  environment action: `SignInLink` ("Sign in", `account.signin`) under "Set a goal" on Next, Plan, Progress and Goal when
  `PlanStore.isSignedIn` is false (signed out, or the server refused the tokens; a signed-in account with no plan only
  offers "Set a goal"), and `SignInAgainButton` under any message starting `SignedOutMessage.prefix`. A new "You've been
  signed out" message must start with that prefix and show the button. The action closes the Inbox, Review, session and
  editor covers first (a sheet cannot open over them) and opens sign-in once they are gone. A sign-in bumps
  `AccountChanges`, which is part of the review, progress, inbox and watch keys so they reload even for the same plan.
  `.environment(\.requestSignIn, ...)` is the last modifier on `RootView`'s body so its covers inherit it. A sheet that
  Goal presents itself (review settings, re-run proposals) is not tracked by `RootView`, so it must not show
  `SignInAgainButton`: the sign-in sheet could not open over it.
- The UI-test API has no sign-in rate limit (every UI test shares one address, and the real per-IP limit of 15 an hour ran out).
