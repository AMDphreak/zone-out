module zoneout.lists;

import std.algorithm : endsWith, filter;
import std.array : array;
import std.string : splitLines, startsWith, strip, toLower;

string[] parseDomainSdl(string text)
{
    string[] domains;
    foreach (raw; text.splitLines)
    {
        auto line = raw.strip;
        if (line.length == 0 || line.startsWith("//") || line.startsWith("#"))
            continue;
        enum prefix = "domain \"";
        if (!line.startsWith(prefix) || line.length < prefix.length + 2)
            continue;
        auto rest = line[prefix.length .. $];
        auto end = rest.indexOf('"');
        if (end <= 0)
            continue;
        auto host = rest[0 .. end].strip.toLower;
        if (host.length)
            domains ~= host;
    }
    return domains;
}

private ptrdiff_t indexOf(string s, char c)
{
    foreach (i, ch; s)
    {
        if (ch == c)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

string[] bundledSeed()
{
    return parseDomainSdl(import("seed.sdl"));
}

string[] bundledDenylist()
{
    return parseDomainSdl(import("denylist.sdl"));
}

/// True if `host` is this entry or a subdomain of it.
bool hostMatchesEntry(string host, string entry)
{
    auto h = host.toLower;
    auto e = entry.toLower;
    if (h == e)
        return true;
    return h.endsWith("." ~ e);
}

bool isDenied(string host, string[] denylist = bundledDenylist())
{
    foreach (entry; denylist)
    {
        if (hostMatchesEntry(host, entry))
            return true;
    }
    return false;
}

string[] filterDenied(string[] hosts, string[] denylist = bundledDenylist())
{
    return hosts.filter!(h => !isDenied(h, denylist)).array;
}

unittest
{
    auto seed = parseDomainSdl(`
        // comment
        domain "grok.com"
        domain "learn.microsoft.com"
    `);
    assert(seed == ["grok.com", "learn.microsoft.com"]);
    assert(isDenied("bucket.s3.amazonaws.com", ["s3.amazonaws.com"]));
    assert(isDenied("drive.google.com", ["drive.google.com"]));
    assert(!isDenied("grok.com", ["drive.google.com"]));
    assert(!hostMatchesEntry("notgithub.io", "github.io"));
    assert(hostMatchesEntry("user.github.io", "github.io"));
}
