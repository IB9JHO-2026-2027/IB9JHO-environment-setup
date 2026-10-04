#include "capture_output.hpp"
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

void capture_output(const std::string& cmd, const std::string& outputFile) {
    std::filesystem::path outputFilePath = outputFile;
    outputFilePath = outputFilePath.lexically_normal();

    #if defined(_WIN32) || defined(_WIN64)
        std::string cmdNormalized = cmd;
        std::replace(cmdNormalized.begin(), cmdNormalized.end(), '\\', '/');

        std::string fullCmd = "cmd.exe /C \"" + cmdNormalized + "\" > \"" + outputFilePath.generic_string() + "\"";
    #else
        std::string fullCmd = "sh -c '" + cmd + " > \"" + outputFilePath.string() + "\" 2>&1'";
    #endif

    int ret = std::system(fullCmd.c_str());

    if (ret != 0)
        throw std::runtime_error("capture_output: Error running the program.");
}