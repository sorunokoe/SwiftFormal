## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `Scripts/safety-net.sh` ends with `SAFETY NET GREEN`.
- [ ] If I changed an engine module (SFSAT, SFCheck, SFBV, SFProve, SFSemantics, SFSIL, SFLLVM): the slow lane passes (`Scripts/test-lane.sh slow`), and the oracle lane for SFSIL, SFSemantics and SFLLVM (`Scripts/test-lane.sh oracle`). Results:
- [ ] I added a test that fails without my change (for a soundness fix: a case in the soundness zoo or the oracle lane).
- [ ] API diff reviewed: `Scripts/check-api.sh` shows nothing I cannot explain, and any new public name follows the [naming guideline](../docs/decisions/0005-api-naming.md).
- [ ] Docs updated (README, guides, DocC comments, `docs/GLOSSARY.md` if a word changed), and `python3 Scripts/check-links.py` is ok.
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]` for every user-visible change.
- [ ] No private paths, secrets or personal details (`python3 Scripts/check-release-hygiene.py`).
