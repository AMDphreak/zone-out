module app;

import std.stdio : stderr, writeln;
import zoneout.cli : run;

int main(string[] args)
{
    version (Windows)
    {
        return run(args);
    }
    else
    {
        stderr.writeln("zone-out is Windows-only (WinINet Zone Map).");
        return 1;
    }
}
