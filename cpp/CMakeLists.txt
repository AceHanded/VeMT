cmake_minimum_required(VERSION 3.15)

project(vemt LANGUAGES CXX)

find_package(ctranslate2 CONFIG REQUIRED)

include(FetchContent)

FetchContent_Declare(
    sentencepiece
    GIT_REPOSITORY https://github.com/google/sentencepiece.git
    GIT_TAG        v0.2.3
)
FetchContent_MakeAvailable(sentencepiece)

add_library(vemt_wrapper SHARED src/vemt_wrapper.cc)

target_compile_features(vemt_wrapper PUBLIC cxx_std_20)

target_link_libraries(vemt_wrapper PRIVATE
    CTranslate2::ctranslate2
    sentencepiece::sentencepiece
    absl::status
)
set_target_properties(vemt_wrapper PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)