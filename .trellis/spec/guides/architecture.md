---
prefix: ARCH
applies_to:
  - lib/**
  - tool/gen_app_icon.py
  - tool/build_readme_assets.py
  - tool/gen_l10n_lookup.py
reviewed: 2026-11-21
---

# Architecture and ownership

### ARCH-01 Imports follow the three layers and keep compile graphs narrow
- **Rule:** `lib/core` imports only `lib/core`; `lib/app` imports `core`
  and `app`; `lib/features` imports `core`, `app`, and never another
  feature. Only router/workspace assembly facades
  (`lib/app/navigation/routes.dart`, `lib/app/navigation/me_workspace_facade.dart`)
  may import `lib/features/**`: `routes.dart` is imported only by
  `lib/app/app.dart` and `lib/app/external_intent_bridge.dart` (R6) and
  must not re-export `lib/features/**` (R7); `me_workspace_facade.dart` is
  imported only by `lib/features/settings/me_dashboard_page.dart`. Callers
  navigate through the zero-feature libraries `route_facade.dart`,
  `route_search_facade.dart`, `route_extras.dart`, and
  `route_query_codecs.dart`. `lib/app/window/desktop_command_bar.dart` is
  imported only by `lib/app/app.dart` (R8); pages and shared widgets use
  `desktop_command_bar_scope.dart`. The test's allow-list stays empty.
- **Why:** Coupling caller facades and `DesktopCommandBarScope` to
  `routes.dart` pulled ~538 `lib/` files into 102 test files, causing
  slow incremental compiles and 4G local OOM kills.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "lib import graph respects layering rules (allow-list must shrink to empty)"
- **Code:** `lib/app/navigation/routes.dart`, `lib/app/navigation/route_facade.dart`, `lib/app/window/desktop_command_bar_scope.dart`

### ARCH-02 Data code lives in core; shared widgets live in app
- **Rule:** Entities, repositories, controllers and stores go in
  `lib/core/<domain>/`; `lib/features` holds no `*_repository.dart`,
  `*_controller.dart` or `*_models.dart`. A widget used by two features
  moves to `lib/app/widgets/` while its state stays with its core owner.
  Features do not define private `_*Tail`, `_*Error`, `_*Empty`, `_*Card`,
  `_*Status` or `_*Placeholder` widgets that duplicate the component layer.
- **Why:** Feature-local copies of feed states and follow buttons drifted
  apart and kept their own follow booleans.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "lib import graph respects layering rules (allow-list must shrink to empty)"
- **Code:** `lib/app/widgets`, `lib/core`

### ARCH-03 Every cross-layer contract has one owner
- **Rule:** Pixiv hosts, headers and user agent come from
  `pixiv_client_identity.dart`; preference keys from `preference_keys.dart`;
  JSON reads from `json_read.dart`; prompts from `showAppSnackBar`; logs
  from `log()`. A change derives from the owner; never declare a second
  copy.
- **Why:** Duplicated host and key constants were updated in one place and
  not the other.
- **Check:** manual
- **Code:** `lib/core/network/pixiv_client_identity.dart`, `lib/core/settings/preference_keys.dart`, `lib/core/entity/json_read.dart`

### ARCH-04 Generated files are changed through their generator
- **Rule:** App icons come from `tool/gen_app_icon.py` (verify with
  `--check`), README images from `tool/build_readme_assets.py`, the
  localization lookup from `tool/gen_l10n_lookup.py` after
  `flutter gen-l10n`, FRB bindings from the matching codegen. Change the
  generator or its inputs and rerun; never edit the output.
- **Why:** Hand edits were overwritten by the next regeneration.
- **Check:** manual
- **Code:** `tool/gen_app_icon.py`, `tool/build_readme_assets.py`, `tool/gen_l10n_lookup.py`, `lib/l10n/lookup.dart`
