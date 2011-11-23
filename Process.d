module xfbuild.Process;

private
{
    import xfbuild.GlobalParams;

    import win32.windef;
    import win32.winuser;
    import win32.winbase;
    import win32.winnls;

    import std.concurrency;
    import std.process;
    import std.stdio;
    import std.string;
    import std.array; 
    import std.utf;
    import std.conv : to;
}

struct SysError
{
    /***********************************************************************

    ***********************************************************************/

    static uint lastCode()
    {
        version (Win32)
            return GetLastError;
        else
            return errno;
    }

    /***********************************************************************

    ***********************************************************************/

    static char[] lastMsg()
    {
        return lookup(lastCode);
    }

    /***********************************************************************

    ***********************************************************************/

    static char[] lookup(uint errcode)
    {
        char[] text;

        version (Win32)
        {
        DWORD  i;
        LPWSTR lpMsgBuf;

        i = FormatMessageW(
            FORMAT_MESSAGE_ALLOCATE_BUFFER |
            FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            errcode,
            MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),                             // Default language
            cast(LPWSTR)&lpMsgBuf,
            0,
            null);

        /* Remove \r\n from error string */
        if (i >= 2)
            i -= 2;

        text = new char[i * 3];
        i    = WideCharToMultiByte(CP_UTF8, 0, lpMsgBuf, i,
                                   cast(PCHAR)text.ptr, text.length, null, null);
        text = text [0 .. i];
        LocalFree(cast(HLOCAL)lpMsgBuf);
        }
        else
        {
            uint  r;
            char* pemsg;

            pemsg = strerror(errcode);
            r     = strlen(pemsg);

            /* Remove \r\n from error string */
            if (pemsg[r - 1] == '\n')
                r--;

            if (pemsg[r - 1] == '\r')
                r--;

            text = pemsg[0..r].dup;
        }

        return text;
    }
}


struct Process
{
    // todo
    void execute()
    {
    }

    // todo
    string toString()
    {
        return "";
    }

    // todo
    struct Result
    {
        int status;
    }


    // todo
    Result wait()
    {
        return Result(0);
    }

    // todo
    ~this()
    {
    }
}


class ProcessExecutionException : Exception
{
    this(string msg) {
        super(msg);
    }
}

void checkProcessFail(Process process)
{
    auto result = process.wait();

    if (result.status != 0)
    {
        auto name = process.toString();

        if (name.length > 255)
            name = name[0 .. 255] ~ " [...]";

        throw new ProcessExecutionException(`"` ~ name ~ `" returned ` ~ to!string(result.status));
    }
}

void execute(Process process)
{
    process.execute();

    if (globalParams.printCommands)
    {
        writeln(process);
    }
}

/**
 *  Loosely based on tango.sys.Process with the following license:
          copyright:   Copyright (c) 2006 Juan Jose Comellas. All rights reserved
          license:     BSD style: $(LICENSE)
          author:      Juan Jose Comellas <juanjo@comellas.com.ar>
 */
void executeAndCheckFail(string[] cmd, size_t affinity)
{
    void runNoAffinity()
    {
        string sys = cmd.join(" ");
        int ret    = system(sys);

        if (ret != 0)
        {
            throw new ProcessExecutionException(`"` ~ sys ~ `" returned ` ~ to!string(ret));
        }
    }

    version (Windows)
    {
        if (!globalParams.manageAffinity)
        {
            runNoAffinity();
        }
        else
        {
            auto  allCmd = cmd.join(" ");
            char* csys   = toUTFz!(char*)(allCmd);

            STARTUPINFOA startup;

            startup.cb         = STARTUPINFO.sizeof;
            startup.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
            startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
            startup.hStdError  = GetStdHandle(STD_ERROR_HANDLE);

            PROCESS_INFORMATION info;

            if (CreateProcessA(
                    null,                               // lpApplicationName
                    csys,
                    null,                               // lpProcessAttributes
                    null,                               // lpThreadAttributes
                    true,                               // bInheritHandles
                    CREATE_SUSPENDED,
                    null,                               // lpEnvironment
                    null,                               // lpCurrentDirectory
                    &startup,                           // lpStartupInfo
                    &info
                    ))
            {
                if (!SetProcessAffinityMask(info.hProcess, affinity))
                {
                    throw new Exception(
                              format(
                                  "SetProcessAffinityMask(%s) failed: %s",
                                  affinity,
                                  SysError.lastMsg
                                  )
                              );
                }

                ResumeThread(info.hThread);
                CloseHandle(info.hThread);

                DWORD rc;
                DWORD exitCode;

                // We clean up the process related data and set the _running
                // flag to false once we're done waiting for the process to
                // finish.
                scope (exit)
                {
                    CloseHandle(info.hProcess);
                }

                rc = WaitForSingleObject(info.hProcess, INFINITE);

                if (rc == WAIT_OBJECT_0)
                {
                    GetExitCodeProcess(info.hProcess, &exitCode);

                    if (exitCode != 0)
                    {
                        throw new ProcessExecutionException(
                                  format("'%s' returned %s.", allCmd, exitCode)
                                  );
                    }
                }
                else if (rc == WAIT_FAILED)
                {
                    throw new ProcessExecutionException(
                              format("'%s' failed with an unknown exit status.", allCmd)
                              );
                }
            }
            else
            {
                throw new ProcessExecutionException(
                          format("Could not execute '%s'.", allCmd)
                          );
            }
        }
    }
    else
    {
        // TODO: affinity
        runNoAffinity();
    }
}

void executeCompilerViaResponseFile(string compiler, string[] args, size_t affinity)
{
    // todo: this might not be good, not sure.
    string rspFile = format("xfbuild.{:x}.rsp", cast(void*)&thisTid);
    string rspData = args.join("\n");

    /+if (globalParams.verbose) {
            Stdout.formatln("running the compiler with:\n%s", rspData);
       }+/
    auto file = File(rspFile, "w");
    file.write(rspData);

    scope (failure) 
    {
        if (globalParams.removeRspOnFail)
        {
            std.file.remove(rspFile);
        }
    }

    scope (success) 
    {
        std.file.remove(rspFile);
    }

    executeAndCheckFail([compiler, "@" ~ rspFile], affinity);
}

size_t getNthAffinityMaskBit(size_t n)
{
    version (Windows)
    {
        /*
         * This basically asks the system for the affinity
         * mask and uses the N-th set bit in it, where
         * N == thread id % number of bits set in the mask.
         *
         * Could be rewritten with intrinsics, but only
         * DMD seems to have these.
         */

        size_t sysAffinity, thisAffinity;

        if (!GetProcessAffinityMask(
                GetCurrentProcess(),
                &thisAffinity,
                &sysAffinity
                ) || 0 == sysAffinity)
        {
            throw new Exception("GetProcessAffinityMask failed");
        }

        size_t i = n;
        size_t affinityMask = 1;

        while (i-- != 0)
        {
            do
            {
                affinityMask <<= 1;

                if (0 == affinityMask)
                {
                    affinityMask = 1;
                }
            }
            while (0 == (affinityMask & thisAffinity));
        }

        affinityMask &= thisAffinity;
        assert(affinityMask != 0);
    }
    else
    {
        // TODO

        assert(n < size_t.sizeof * 8);
        size_t affinityMask = 1;
        affinityMask <<= n;
    }

    return affinityMask;
}