// Excerpt of lib/SIL/Parser/ParseSIL.cpp at swift-6.4.0-RELEASE (see Scripts/pin-upgrade/fixtures/README.md).
static bool parseAccessEnforcement(StringRef attr) {
  if (attr == "unknown") {
  } else if (attr == "static") {
  } else if (attr == "dynamic") {
  } else if (attr == "non_nested") {
  }
}
