#pragma once
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>

typedef struct HMCPChild HMCPChild;
HMCPChild *hmcp_launch(const wchar_t *executable, wchar_t *environment,
                      uintptr_t input, uintptr_t output, uint32_t *error);
uint32_t hmcp_pid(HMCPChild *child);
int hmcp_poll(HMCPChild *child, uint32_t *exit_code);
int hmcp_stop(HMCPChild *child);
size_t hmcp_output(HMCPChild *child, int standard_error, void *bytes, size_t capacity);
void hmcp_destroy(HMCPChild *child);
