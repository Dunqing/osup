"""Point gh-stack's GraphQL Client methods at ccr_rest.go: python3 apply.py <gh-stack checkout>.
Each method that calls c.gql gets `return c.rest<Name>(args)` as its first statement. Fails if a
GraphQL method has no REST version or one is left unused, so an upstream change stops the build."""
import pathlib, re, shutil, sys

gh = pathlib.Path(sys.argv[1]) / "internal/github"
rest = shutil.copy(pathlib.Path(__file__).with_name("ccr_rest.go"), gh / "ccr_rest.go")
have = set(re.findall(r"^func \(c \*Client\) rest(\w+)\(", pathlib.Path(rest).read_text(), re.M))
used = set()
sig = re.compile(r"^func \(c \*Client\) (\w+)\(([^)]*)\)[^{\n]*\{\n", re.M)

def arg_names(params):  # "a, b string, d bool" -> "a, b, d"
    return ", ".join(p.split()[0] for p in params.split(",") if p.strip())

for f in ("github.go", "merge_async.go"):
    path = gh / f; src = path.read_text(); out, pos = [], 0
    for m in sig.finditer(src):
        end = src.find("\n}\n", m.end())
        if "c.gql." not in src[m.end():end]:
            continue
        name = m.group(1)[0].upper() + m.group(1)[1:]
        if name not in have:
            sys.exit(f"apply.py: {f}: {m.group(1)} uses GraphQL and has no REST version")
        used.add(name)
        out += [src[pos:m.end()], f"\treturn c.rest{name}({arg_names(m.group(2))})\n"]; pos = m.end()
    path.write_text("".join(out) + src[pos:])
if have - used - {"PullRequest", "PRsForHead", "PRRoute"}:
    sys.exit(f"apply.py: REST versions with no GraphQL method: {sorted(have - used)}")
print(f"apply.py: {len(used)} GraphQL methods now use REST")
