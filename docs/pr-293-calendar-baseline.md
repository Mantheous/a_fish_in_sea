# PR #293: clean-main calendar baseline

Review fix item 1 was reproduced on 2026-11-02. The calendar golden failure
predates the auth tests in this PR and is tracked separately in
[issue #294](https://github.com/Mantheous/a_fish_in_sea/issues/294).
No runtime code, test expectation, or golden baseline was changed in rework.

## Identical conditions

- Main: `6db1cb8035f8fe9ef723939fe17c60c78bda2234`.
- PR head tested: `c9b9f7fbddec81d86f2b88e26daa76f89610c5e1`.
- Same Linux host, Flutter 3.47.2 (`d3b14c8769`), Dart 3.13.2, `TZ=UTC`.
- Identical `pubspec.lock` SHA-256:
  `9fd61572d6dfa12c709de12c802781fd02d9b1cfda82b4c8c8e9ae6c0f4ffada`.

To stay inside the assigned worktree without altering another checkout,
clean main was extracted using:

```bash
mkdir -p build/rework-293-clean-main
git archive origin/main | tar -x -C build/rework-293-clean-main
```

After `flutter pub get --offline` in that snapshot, the following command
was run in both the branch root and snapshot root:

```bash
TZ=UTC ~/flutter/bin/flutter test test/goldens/calendar_grid_alignment_test.dart \
  --plain-name '2026-11-01 00:00:00.000 Week aligns reports from 6.0' \
  --reporter expanded
```

Both exited 1 with the same failure:

```text
Golden "../goldens/calendar_grid_alignment.week.png": Pixel test failed,
0.10%, 919px diff detected.
```

After testing, all 746 tracked files in the main snapshot were compared
byte-for-byte against `git archive origin/main`; none differed.

## Image evidence

Both revisions used the same untouched expected image and generated
byte-identical actual and isolated-diff images. SHA-256 values:

| Image | SHA-256 on both revisions |
| --- | --- |
| `calendar_grid_alignment.week.png` | `2d7d045b3836af45b5f2c46f035a172f536caaacf6044fcf86c7ce58de25b639` |
| `calendar_grid_alignment.week_testImage.png` | `4c5dd59cd404aef68c5e88896cbe800ecfe127b579b0ae4c31b0f3aef88d8091` |
| `calendar_grid_alignment.week_isolatedDiff.png` | `33fbee98b4561c769102ea38ecfc8adf54630063bc7c9de6ce6383864058270e` |

Host logs are under this worktree's ignored `build/` directory:
`rework-293-main-calendar.log`, `rework-293-branch-calendar.log`,
`rework-293-analyze.log`, and `rework-293-test.log`.
Failure images are in each tested root's `test/goldens/failures/`.

## Rework gates

- `~/flutter/bin/flutter analyze`: exit 0, no issues found.
- `~/flutter/bin/flutter test --reporter expanded`: exit 1,
  1,624 passed and one failed, solely the calendar golden above.

The required all-pass gate remains unmet. Per the review's explicit
clean-main alternative, the existing failure is documented and tracked
separately rather than changing an unrelated golden or weakening tests.
This evidence-only rework requires no additional application test;
the existing failing test was rerun on both revisions.
