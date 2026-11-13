#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <cstring>
#include <exception>
#include <sentencepiece_processor.h>

#include "vemt_wrapper.h"
#include "ctranslate2/translator.h"

/**
 * Contains a CTranslate2 `Translator` instance and SentencePiece `SentencePieceProcessor` instances for both the source and target models.
 */
struct TranslatorHandle {
    sentencepiece::SentencePieceProcessor source_processor;
    sentencepiece::SentencePieceProcessor target_processor;
    std::unique_ptr<ctranslate2::Translator> translator;
};

/**
 * Creates and initializes a translator instance.
 *
 * @param ct2_model_path path to the CTranslate2 model directory.
 * @param spm_source_path path to the source SentencePiece model file.
 * @param spm_target_path path to the target SentencePiece model file.
 * @return a pointer to the created `TranslatorHandle`, or nullptr if creation fails.
 */
TranslatorHandle* create_translator(const char* ct2_model_path, const char* spm_source_path, const char* spm_target_path) {
    if (!ct2_model_path || !spm_source_path || !spm_target_path) return nullptr;

    try {
        auto handle = std::make_unique<TranslatorHandle>();
        auto source_status = handle->source_processor.Load(spm_source_path);

        if (!source_status.ok()) {
            std::cerr << "Source tokenizer error: " << source_status.ToString() << '\n';

            return nullptr;
        }
        auto target_status = handle->target_processor.Load(spm_target_path);

        if (!target_status.ok()) {
            std::cerr << "Target tokenizer error: " << target_status.ToString() << '\n';

            return nullptr;
        }
        handle->translator = std::make_unique<ctranslate2::Translator>(ct2_model_path, ctranslate2::Device::CPU);

        return handle.release();
    } catch (const std::exception& e) {
        std::cerr << "Translator creation error: " << e.what() << '\n';

        return nullptr;
    } catch (...) {
        std::cerr << "Unknown translator creation error\n";

        return nullptr;
    }
}

/**
 * Translates the given input string.
 *
 * @param translator pointer to the `TranslatorHandle` instance.
 * @param input the input string to translate.
 * @return the translated output string, or nullptr if translation fails.
 */
char* translate(TranslatorHandle* translator, const char* input) {
    if (!translator || !input) return nullptr;

    try {
        std::vector<std::string> pieces;
        auto encode_status = translator->source_processor.Encode(input, &pieces);

        if (!encode_status.ok()) {
            std::cerr << "Tokenization error: " << encode_status.ToString() << '\n';

            return nullptr;
        }
        std::vector<std::vector<std::string>> batch;
        std::vector<std::string> sentence;

        // Rudimentary sentence splitting
        for (const auto& token : pieces) {
            sentence.push_back(token);

            if (token == "." || token == "!" || token == "?") {
                batch.push_back(std::move(sentence));
                sentence.clear();
            }
        }

        if (!sentence.empty()) {
            batch.push_back(std::move(sentence));
        }
        const auto results = translator->translator->translate_batch(batch);

        if (results.empty() || results[0].output().empty()) {
            std::cerr << "Translation returned no output\n";

            return nullptr;
        }
        std::string text;

        for (size_t i = 0; i < results.size(); i++) {
            std::string sentence_text;
            auto decode_status = translator->target_processor.Decode(results[i].output(), &sentence_text);

            if (!decode_status.ok()) {
                std::cerr << "Detokenization error: " << decode_status.ToString() << '\n';

                return nullptr;
            }

            if (!text.empty()) {
                text += " ";
            }
            text += sentence_text;
        }
        char* output = new char[text.size() + 1];

        std::memcpy(output, text.c_str(), text.size() + 1);

        return output;
    } catch (const std::exception& e) {
        std::cerr << "Translation error: " << e.what() << '\n';

        return nullptr;
    } catch (...) {
        std::cerr << "Unknown translation error\n";

        return nullptr;
    }
}

/**
 * Frees a string allocated by `translate`.
 *
 * @param text pointer to the string to free.
 */
void free_string(char* text) {
    delete[] text;
}

/**
 * Destroys the translator instance and frees its allocated memory.
 *
 * @param translator pointer to the `TranslatorHandle` instance.
 */
void destroy_translator(TranslatorHandle* translator) {
    delete translator;
}
