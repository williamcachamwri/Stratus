## Summary

- 

## Type

- [ ] feat
- [ ] fix
- [ ] refactor
- [ ] test
- [ ] docs
- [ ] ci/chore

## Validation

- [ ] `swift build --product Stratus`
- [ ] `Scripts/test.sh`
- [ ] `Scripts/lint.sh`
- [ ] `Scripts/build_unsigned_release.sh`
- [ ] Not run; reason:

## Repository rule checklist

- [ ] Every changed file is committed separately.
- [ ] No `git add .`, `git add -A`, or broad wildcard staging was used.
- [ ] Every commit uses Conventional Commits.
- [ ] Every commit includes:

```text
Co-Authored-By: williamcachamwri <2741582+williamcachamwri@users.noreply.github.com>
```

## Security and release checklist

- [ ] No secrets, access tokens, private Sparkle keys, Apple certificates, provisioning profiles, `.p12`, `.pem`, `.key`, `.env`, or private xcconfig files are committed.
- [ ] Unsigned local builds still work; no Developer ID certificate is required.
- [ ] User-facing errors explain what failed and how to recover.
- [ ] UI changes follow the anti-AI-design checklist in the Stratus prompt.
