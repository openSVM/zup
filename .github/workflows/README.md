# CI/CD Workflows

## gRPC Tests Workflow

This workflow runs the gRPC tests in an isolated Docker container on GitHub Actions.

### Features

- Runs on every push to main and pull requests
- Uses Docker with resource limits:
  - 2GB memory limit
  - 2 CPU cores limit
  - 45 second timeout per test
- Preserves test logs as artifacts
- Can be triggered manually via workflow_dispatch

### Local Testing

To run the same tests locally before pushing:

```bash
./scripts/run_grpc_tests_safe.sh
```

### Monitoring

1. View test results in the GitHub Actions tab
2. Download test logs from the workflow artifacts
3. Check container resource usage in the workflow logs

### Troubleshooting

If tests fail in CI but pass locally:
1. Check the container logs in GitHub Actions
2. Verify resource limits aren't being hit
3. Look for network-related issues in the gRPC tests
4. Compare the test environment differences:
   - CI uses Ubuntu latest
   - Resource constraints may be different
   - Network configuration may vary

### Alternative CI Services

While this workflow uses GitHub Actions, the tests can also be run on:

1. CircleCI
   - Good Docker support
   - Free tier available
   - Easy to migrate using orbs

2. GitLab CI
   - Built-in container registry
   - Auto-scaling runners
   - YAML configuration similar to GitHub Actions

3. AWS CodeBuild
   - Pay-per-use pricing
   - Deep AWS integration
   - Good for large-scale testing

To migrate to another service, the core Docker commands remain the same - only the CI configuration syntax needs to be adapted.
