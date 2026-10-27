# Vendored LuaCov

Unmodified copy of [LuaCov](https://github.com/lunarmodules/luacov) at commit
`645a98468aad737de035a49a578c245bb3e555fb` (master after v0.15.0).

Why the commit instead of the v0.15.0 tag: v0.15.0 assigns to a generic-`for`
control variable in `luacov/reporter.lua`, which is a load-time error under the
Lua 5.4+ semantics used by the `lupa` runtime in this test suite.

Used by `tests/support.py` when `DOS3_LUA_COVERAGE=1`, and by
`scripts/check-coverage.py`. License: MIT, see `LICENSE`.

The HTML reporter (`luacov/reporter/html.lua` and its static assets) is omitted;
only the default summary reporter is used.

To update:

```bash
curl -fsSL -o /tmp/luacov.tar.gz \
  https://github.com/lunarmodules/luacov/archive/<commit>.tar.gz
tar -xzf /tmp/luacov.tar.gz -C /tmp/luacov-new --strip-components=1
cp -r /tmp/luacov-new/src/luacov /tmp/luacov-new/src/luacov.lua \
  /tmp/luacov-new/LICENSE tests/vendor/luacov/
```
