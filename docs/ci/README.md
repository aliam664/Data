# Windows CI workflow template

`windows-test-workflow.yml` is the ready-to-use GitHub Actions workflow for validating UHM Launcher on Windows.

It is intentionally stored under `docs/ci/` because the GitHub App used to publish this branch does not have the `workflows` permission and GitHub rejects pushes that modify `.github/workflows/`.

A repository maintainer with Workflow permission can enable it without changing its contents:

```powershell
New-Item -ItemType Directory -Force .github\workflows | Out-Null
Copy-Item docs\ci\windows-test-workflow.yml .github\workflows\test.yml
```

Before enabling it, review action versions and repository policy. Relocating the file does not change runtime behavior or remove any test; it only prevents the limited publishing credential from modifying GitHub Actions configuration.
