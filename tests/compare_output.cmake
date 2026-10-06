# Run a program and check that its standard output matches an expected file.
#
# Usage (normally via add_test in tests/CMakeLists.txt):
#   cmake -DPROGRAM=<executable> -DEXPECTED=<file> -DACTUAL=<file>
#         [-DINPUT=<file>] -P compare_output.cmake
#
#   PROGRAM   the executable to run (it is given no arguments)
#   EXPECTED  text file holding the expected output
#   ACTUAL    file the program's output is written to, for inspection afterwards
#   INPUT     optional text file whose contents are fed to the program's
#             standard input (for programs that read with std::cin)
#
# The program is started directly rather than through a shell, so paths that
# contain spaces or quotes work on every platform. Before comparing, Windows
# line endings (CRLF) are converted to LF and blank lines at the very end of
# either text are ignored; every other character, including spaces, must match
# exactly. On a mismatch the first differing line is reported with both
# versions shown in quotes so that stray or missing spaces are visible.
#
# The script exits with a non-zero status (failing the CTest test) if the
# program cannot be run, exits with an error, or prints the wrong output.

cmake_minimum_required(VERSION 3.21)

foreach(required_variable IN ITEMS PROGRAM EXPECTED ACTUAL)
    if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
        message(FATAL_ERROR "compare_output.cmake: pass -D${required_variable}=<path>")
    endif()
endforeach()

if(NOT EXISTS "${EXPECTED}")
    message(FATAL_ERROR "Expected output file not found: ${EXPECTED}")
endif()

# Feed the optional input file to the program's standard input.
set(input_arguments "")
if(DEFINED INPUT AND NOT "${INPUT}" STREQUAL "")
    if(NOT EXISTS "${INPUT}")
        message(FATAL_ERROR "Input file not found: ${INPUT}")
    endif()
    set(input_arguments INPUT_FILE "${INPUT}")
endif()

execute_process(
    COMMAND "${PROGRAM}"
    ${input_arguments}
    OUTPUT_FILE "${ACTUAL}"
    ERROR_VARIABLE program_errors
    RESULT_VARIABLE program_result
    TIMEOUT 60
)
# RESULT_VARIABLE holds the exit code, or a description such as
# "Segmentation fault" if the program crashed or timed out.
if(NOT "${program_result}" STREQUAL "0")
    message(NOTICE "${program_errors}")
    message(FATAL_ERROR "${PROGRAM} did not finish successfully: ${program_result}")
endif()

# Read a text file into out_var, normalising its line endings and removing
# trailing blank lines so that the comparison is platform independent.
function(read_normalised_text path out_var)
    file(READ "${path}" text)
    string(REPLACE "\r\n" "\n" text "${text}")
    string(REGEX REPLACE "\n+$" "" text "${text}")
    set(${out_var} "${text}" PARENT_SCOPE)
endfunction()

# Remove the first line from the text held in text_var and store it in
# line_var. done_var must start as FALSE for non-empty text; it is set to TRUE
# once the last line has been taken, and while TRUE no line is returned.
function(take_line text_var line_var done_var)
    if(${done_var})
        return()
    endif()
    set(text "${${text_var}}")
    string(FIND "${text}" "\n" newline)
    if(newline EQUAL -1)
        set(${line_var} "${text}" PARENT_SCOPE)
        set(${text_var} "" PARENT_SCOPE)
        set(${done_var} TRUE PARENT_SCOPE)
    else()
        string(SUBSTRING "${text}" 0 ${newline} line)
        math(EXPR rest_start "${newline} + 1")
        string(SUBSTRING "${text}" ${rest_start} -1 rest)
        set(${line_var} "${line}" PARENT_SCOPE)
        set(${text_var} "${rest}" PARENT_SCOPE)
    endif()
endfunction()

read_normalised_text("${EXPECTED}" expected_text)
read_normalised_text("${ACTUAL}" actual_text)

if("${actual_text}" STREQUAL "${expected_text}")
    message(STATUS "Output matches ${EXPECTED}")
    return()
endif()

# The texts differ: walk through them line by line to find the first difference.
set(expected_done FALSE)
set(actual_done FALSE)
if("${expected_text}" STREQUAL "")
    set(expected_done TRUE)
endif()
if("${actual_text}" STREQUAL "")
    set(actual_done TRUE)
endif()

set(line_number 0)
while(TRUE)
    math(EXPR line_number "${line_number} + 1")
    set(expected_finished ${expected_done})
    set(actual_finished ${actual_done})
    set(expected_line "")
    set(actual_line "")
    take_line(expected_text expected_line expected_done)
    take_line(actual_text actual_line actual_done)

    # Defensive: unreachable while the texts differ, but guarantees termination.
    if(expected_finished AND actual_finished)
        set(report "The outputs differ.")
        break()
    endif()
    if(actual_finished AND NOT expected_finished)
        math(EXPR last_line "${line_number} - 1")
        string(CONCAT report
            "Your output has only ${last_line} line(s), but more were expected.\n"
            "  expected line ${line_number}: \"${expected_line}\"")
        break()
    endif()
    if(expected_finished AND NOT actual_finished)
        math(EXPR last_line "${line_number} - 1")
        string(CONCAT report
            "Your output has more lines than expected (expected ${last_line}).\n"
            "  extra line ${line_number}: \"${actual_line}\"")
        break()
    endif()
    if(NOT "${actual_line}" STREQUAL "${expected_line}")
        string(CONCAT report
            "Line ${line_number} is different.\n"
            "  expected: \"${expected_line}\"\n"
            "  actual:   \"${actual_line}\"")
        break()
    endif()
endwhile()

message(NOTICE "${report}\n\nExpected output: ${EXPECTED}\nYour output:     ${ACTUAL}\n")
message(FATAL_ERROR "The program output does not match the expected output.")
