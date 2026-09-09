# Keep options unchanged, then resolve freshly built and published Omarchy
# packages before distribution repositories. Preserve each section verbatim.
/^[[:space:]]*\[/ {
  section = $0
  sub(/^[[:space:]]*\[/, "", section)
  sub(/\].*$/, "", section)
}
section == "omarchy-build" { built = built $0 "\n"; next }
section == "omarchy" { published = published $0 "\n"; next }
section == "options" || section == "" { options = options $0 "\n"; next }
{ distribution = distribution $0 "\n" }
END { printf "%s%s%s%s", options, built, published, distribution }
