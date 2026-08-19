module zoneout.domain;

import std.algorithm : canFind, endsWith, splitter;
import std.array : join, split;
import std.string : strip, toLower, startsWith;

/// Parsed Public Suffix List (ICANN + private rules, as shipped in the dat file).
struct PublicSuffixList
{
    bool[string] rules;
    bool[string] wildcards;
    bool[string] exceptions;
}

PublicSuffixList parsePsl(string text)
{
    PublicSuffixList psl;
    foreach (raw; text.splitter('\n'))
    {
        auto line = raw.strip;
        if (line.length == 0 || line.startsWith("//"))
            continue;
        if (line[$-1] == '\r')
            line = line[0 .. $-1].strip;
        if (line.length == 0 || line.startsWith("//"))
            continue;
        auto lower = line.toLower;
        if (lower.startsWith("!"))
            psl.exceptions[lower[1 .. $]] = true;
        else if (lower.startsWith("*."))
            psl.wildcards[lower[2 .. $]] = true;
        else
            psl.rules[lower] = true;
    }
    return psl;
}

string[] labelsOf(string host)
{
    string[] labels;
    foreach (part; host.toLower.splitter('.'))
    {
        auto p = part.strip;
        if (p.length)
            labels ~= p;
    }
    return labels;
}

/// Public suffix (e.g. `com`, `co.uk`). Default rule is `*` (last label).
string publicSuffix(const ref PublicSuffixList psl, string host)
{
    auto labels = labelsOf(host);
    if (labels.length == 0)
        return null;

    string exception;
    string bestRule;
    size_t bestRuleLabels;
    string bestWild;
    size_t bestWildLabels;

    foreach (i; 0 .. labels.length)
    {
        auto suffix = labels[i .. $].join(".");
        if (suffix in psl.exceptions)
            exception = suffix;
        if (suffix in psl.rules)
        {
            auto n = labels.length - i;
            if (n >= bestRuleLabels)
            {
                bestRuleLabels = n;
                bestRule = suffix;
            }
        }
        if (i + 1 < labels.length)
        {
            auto rest = labels[i + 1 .. $].join(".");
            if (rest in psl.wildcards)
            {
                auto n = labels.length - i;
                if (n >= bestWildLabels)
                {
                    bestWildLabels = n;
                    bestWild = suffix;
                }
            }
        }
    }

    if (exception.length)
    {
        auto el = exception.split(".");
        if (el.length <= 1)
            return exception;
        return el[1 .. $].join(".");
    }

    if (bestWildLabels > bestRuleLabels)
        return bestWild;
    if (bestRule.length)
        return bestRule;
    return labels[$ - 1];
}

/// Registrable / eTLD+1 domain. `null` if `host` is itself a public suffix.
string registrableDomain(const ref PublicSuffixList psl, string host)
{
    auto labels = labelsOf(host);
    auto ps = publicSuffix(psl, host);
    if (labels.length == 0 || ps is null)
        return null;
    auto psLabels = labelsOf(ps);
    if (labels.length <= psLabels.length)
        return null;
    auto n = psLabels.length + 1;
    return labels[$ - n .. $].join(".");
}

struct ZoneMapSplit
{
    string apex; /// registrable domain (registry key under Domains)
    string leftover; /// optional subkey (may contain dots), empty for apex-only
    string host; /// normalized host (no scheme/path)
}

string normalizeHost(string input)
{
    auto s = input.strip.toLower;
    if (s.startsWith("https://"))
        s = s["https://".length .. $];
    else if (s.startsWith("http://"))
        s = s["http://".length .. $];
    auto slash = s.indexOfAny("/:?#");
    if (slash >= 0)
        s = s[0 .. slash];
    if (s.startsWith("*."))
        s = s[2 .. $];
    if (s.endsWith("."))
        s = s[0 .. $ - 1];
    return s;
}

private ptrdiff_t indexOfAny(string s, string chars)
{
    foreach (i, c; s)
    {
        if (chars.canFind(c))
            return cast(ptrdiff_t) i;
    }
    return -1;
}

ZoneMapSplit splitForZoneMap(const ref PublicSuffixList psl, string input)
{
    ZoneMapSplit result;
    result.host = normalizeHost(input);
    if (result.host.length == 0)
        return result;
    result.apex = registrableDomain(psl, result.host);
    if (result.apex is null || result.apex.length == 0)
        return result;
    if (result.host == result.apex)
        return result;
    auto suffix = "." ~ result.apex;
    if (result.host.endsWith(suffix))
        result.leftover = result.host[0 .. $ - suffix.length];
    return result;
}

unittest
{
    auto psl = parsePsl("com\nuk\nco.uk\njp\nco.jp\n");
    assert(publicSuffix(psl, "www.example.com") == "com");
    assert(registrableDomain(psl, "www.example.com") == "example.com");
    assert(registrableDomain(psl, "example.co.uk") == "example.co.uk");
    assert(registrableDomain(psl, "www.example.co.uk") == "example.co.uk");
    auto z = splitForZoneMap(psl, "https://learn.microsoft.com/en-us/windows");
    assert(z.apex == "microsoft.com");
    assert(z.leftover == "learn");
    auto g = splitForZoneMap(psl, "GROK.COM");
    assert(g.apex == "grok.com");
    assert(g.leftover.length == 0);
}

unittest
{
    auto psl = parsePsl(import("public-suffix-list.dat"));
    assert(registrableDomain(psl, "www.example.co.uk") == "example.co.uk");
    assert(registrableDomain(psl, "learn.microsoft.com") == "microsoft.com");
    auto z = splitForZoneMap(psl, "gemini.google.com");
    assert(z.apex == "google.com");
    assert(z.leftover == "gemini");
}
