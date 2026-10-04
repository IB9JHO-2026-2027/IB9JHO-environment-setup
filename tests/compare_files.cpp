#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "compare_files.hpp"

void compare_files(const std::string& file1, const std::string& file2) {
    std::ifstream file1_stream(file1);
    std::ifstream file2_stream(file2);

    if (!file1_stream.is_open()) {
        throw std::runtime_error("compare_files: Failed to open file: " + file1);
    }

    if (!file2_stream.is_open()) {
        throw std::runtime_error("compare_files: Failed to open file: " + file2);
    }

    std::string file1_output((std::istreambuf_iterator<char>(file1_stream)), std::istreambuf_iterator<char>());
    std::string file2_output((std::istreambuf_iterator<char>(file2_stream)), std::istreambuf_iterator<char>());

    if (file1_output != file2_output) {
        throw std::runtime_error("compare_files: The files are not the same");
    }
}
