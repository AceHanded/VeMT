#ifndef VEMT_WRAPPER_H
#define VEMT_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TranslatorHandle TranslatorHandle;

TranslatorHandle* create_translator(const char* model_path, const char* source_model_path, const char* target_model_path);

char* translate(TranslatorHandle* translator, const char* input);

void free_string(char* text);

void destroy_translator(TranslatorHandle* translator);

#ifdef __cplusplus
}
#endif

#endif  // VEMT_WRAPPER_H
