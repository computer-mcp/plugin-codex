#include "HostProcess.h"
#include <windows.h>
#include <stdlib.h>
#include <string.h>

struct HMCPChild {
    HANDLE process, job, output, error;
    DWORD pid;
};

static void close_handle(HANDLE *handle) {
    if (*handle) CloseHandle(*handle);
    *handle = NULL;
}

static BOOL pipe_pair(HANDLE *read, HANDLE *write) {
    SECURITY_ATTRIBUTES security = { sizeof(security), NULL, TRUE };
    if (!CreatePipe(read, write, &security, 4096)) return FALSE;
    return SetHandleInformation(*read, HANDLE_FLAG_INHERIT, 0);
}

// The fixture host lends precisely two callback endpoints to a suspended child.
// Standard streams are separate. No name, listener, or credential is created.
HMCPChild *hmcp_launch(const wchar_t *executable, wchar_t *environment,
                      uintptr_t input, uintptr_t output, uint32_t *error) {
    HMCPChild *child = calloc(1, sizeof(*child));
    HANDLE stdin_read = NULL, stdin_write = NULL, stdout_write = NULL, stderr_write = NULL;
    PROCESS_INFORMATION process = {0};
    STARTUPINFOEXW startup = {0};
    SIZE_T size = 0;
    BOOL initialized = FALSE;
    wchar_t *command = NULL;
    DWORD failure = ERROR_NOT_ENOUGH_MEMORY;
    if (!child) goto cleanup;
    child->job = CreateJobObjectW(NULL, NULL);
    if (!child->job) goto failed;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(child->job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits))) goto failed;
    if (!pipe_pair(&child->output, &stdout_write) ||
        !pipe_pair(&child->error, &stderr_write) ||
        !pipe_pair(&stdin_read, &stdin_write)) goto failed;
    close_handle(&stdin_write);
    if (!SetHandleInformation(stdin_read, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) goto failed;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    startup.lpAttributeList = malloc(size);
    if (!startup.lpAttributeList) goto cleanup;
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &size)) goto failed;
    initialized = TRUE;
    HANDLE inherited[] = { stdin_read, stdout_write, stderr_write, (HANDLE)input, (HANDLE)output };
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited, sizeof(inherited), NULL, NULL)) goto failed;
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = stdin_read;
    startup.StartupInfo.hStdOutput = stdout_write;
    startup.StartupInfo.hStdError = stderr_write;
    size_t count = wcslen(executable);
    command = calloc(count + 3, sizeof(wchar_t));
    if (!command) goto cleanup;
    command[0] = L'"';
    memcpy(command + 1, executable, count * sizeof(wchar_t));
    command[count + 1] = L'"';
    if (!CreateProcessW(executable, command, NULL, NULL, TRUE,
                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
                        environment, NULL, &startup.StartupInfo, &process)) goto failed;
    child->process = process.hProcess;
    child->pid = process.dwProcessId;
    if (!AssignProcessToJobObject(child->job, child->process)) goto failed;
    if (ResumeThread(process.hThread) == (DWORD)-1) goto failed;
    failure = ERROR_SUCCESS;
    goto cleanup;
failed:
    failure = GetLastError();
cleanup:
    close_handle(&process.hThread);
    close_handle(&stdin_read);
    close_handle(&stdin_write);
    close_handle(&stdout_write);
    close_handle(&stderr_write);
    if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    free(command);
    *error = failure;
    if (failure != ERROR_SUCCESS) {
        if (child && child->process) {
            TerminateProcess(child->process, 1);
            WaitForSingleObject(child->process, 5000);
        }
        hmcp_destroy(child);
        return NULL;
    }
    return child;
}

uint32_t hmcp_pid(HMCPChild *child) { return child->pid; }

int hmcp_poll(HMCPChild *child, uint32_t *exit_code) {
    DWORD state = WaitForSingleObject(child->process, 0);
    if (state == WAIT_TIMEOUT) return 0;
    DWORD code = 0;
    if (state != WAIT_OBJECT_0 || !GetExitCodeProcess(child->process, &code)) return -1;
    *exit_code = code;
    return 1;
}

int hmcp_stop(HMCPChild *child) {
    if (!child) return 1;
    if (!TerminateJobObject(child->job, 1)) return 0;
    return WaitForSingleObject(child->process, 5000) == WAIT_OBJECT_0;
}

size_t hmcp_output(HMCPChild *child, int standard_error, void *bytes, size_t capacity) {
    HANDLE pipe = standard_error ? child->error : child->output;
    DWORD available = 0, count = 0;
    if (!PeekNamedPipe(pipe, NULL, 0, NULL, &available, NULL)) return 0;
    DWORD size = available < capacity ? available : (DWORD)capacity;
    if (size == 0 || !ReadFile(pipe, bytes, size, &count, NULL)) return 0;
    return count;
}

void hmcp_destroy(HMCPChild *child) {
    if (!child) return;
    if (child->process) hmcp_stop(child);
    close_handle(&child->process);
    close_handle(&child->job);
    close_handle(&child->output);
    close_handle(&child->error);
    free(child);
}
