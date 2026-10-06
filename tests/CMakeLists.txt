# Output test for the environment check.
#
# The check_output test runs my_program and compares what it prints with
# tests/IO/correct_output.txt. The comparison is done by compare_output.cmake
# rather than a shell command, so it behaves identically on Windows, macOS and
# Linux, including when the repository is stored in a folder whose path
# contains spaces.

add_test(
    NAME check_output
    COMMAND ${CMAKE_COMMAND}
        -DPROGRAM=$<TARGET_FILE:my_program>
        -DEXPECTED=${CMAKE_CURRENT_SOURCE_DIR}/IO/correct_output.txt
        -DACTUAL=${CMAKE_CURRENT_BINARY_DIR}/program_output.txt
        -P ${CMAKE_CURRENT_SOURCE_DIR}/compare_output.cmake
)
