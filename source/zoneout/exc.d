module zoneout.exc;

class ZoneOutException : Exception
{
    int exitCode;

    this(string msg, int exitCode, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.exitCode = exitCode;
    }
}

enum Exit : int
{
    ok = 0,
    error = 1,
    usage = 2,
    notElevated = 3,
    denied = 4,
}
