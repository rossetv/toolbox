# AGPL distribution posture

The repo carries AGPL-3.0-or-later (forced by the bundled Ghostscript dependency) and
is developed **privately**; the user flips it **public at or before release**. AGPL
obligations trigger on distribution, not on private development, so this is
compliant — but it means the repo must not go public with any privacy-sensitive
content still in it (see personal-test-material below), and any future dependency
choice that would force a stricter licence (e.g. GPL without the "or later"/network
clause) needs the same explicit accept-the-tradeoff conversation this one got. The
Mac App Store is **permanently** foreclosed by AGPL — do not resurface it as an option
without a licence change decision first.

Standing authorisation boundary: **never write, in any committed file, anything about
the user's personal local PDF test material** — no path, no filename, no folder name,
no subject matter, not even that such a corpus exists at a specific location. Describe
test material only generically ("a synthetic fixture corpus", "a local sample set").
This applies with extra force once the repo goes public, but holds from day one.
