# example-package

## Identity
- **Devel project**: devel:your:project
- **Branch**: home:user:branches:devel:your:project
- **Version**: 1.0.0
- **License**: MIT
- **URL**: https://github.com/example/package
- **Ecosystem**: python
- **Build system**: pyproject
- **Source service**: download_files
- **Last maintainer**: Your Name <email@example.com>

## Dependencies
### BuildRequires
- `python3-setuptools`
- `python3-wheel`

### Requires
- `python3-requests >= 2.28`

## Patches
None.

## Testing
Tests run during build. No skipped tests.

## Known Issues
- 15.6/x86_64 unresolvable: missing python3-some-dep, not available for SLE 15 SP6

## Build History
- 2026-03-28: Version bump 0.9.0 → 1.0.0, added new dep python3-requests

## Notes
- Upstream uses calendar versioning (YY.M.patch)
- Co-maintained with another-user on OBS
