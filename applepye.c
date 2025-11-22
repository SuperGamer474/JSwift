// applepye.c
#include "applepye.h"
#include <Python.h>
#include <stdlib.h>
#include <string.h>

// Helper to duplicate C string (malloced)
static char* _dup_str(const char* s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char* out = (char*)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, s, n + 1);
    return out;
}

void applepye_initialize(void) {
    if (!Py_IsInitialized()) {
        Py_Initialize();
        // Optional: initialize threads if you plan to use threads
        PyEval_InitThreads();
        // Acquire and release GIL so main thread is ready
        PyEval_SaveThread();
    }
}

void applepye_finalize(void) {
    if (Py_IsInitialized()) {
        PyGILState_STATE gstate = PyGILState_Ensure();
        Py_Finalize();
        PyGILState_Release(gstate);
    }
}

char* applepye_execute(const char* code_c) {
    if (!code_c) return _dup_str("");
    const char* wrapper =
        "import sys, io\n"
        "_applepye_old_stdout = sys.stdout\n"
        "_applepye_old_stderr = sys.stderr\n"
        "_applepye_buf = io.StringIO()\n"
        "sys.stdout = _applepye_buf\n"
        "sys.stderr = _applepye_buf\n"
        "def _applepye_run(code):\n"
        "    try:\n"
        "        # try as expression first to return value\n"
        "        val = eval(code, globals())\n"
        "        if val is not None:\n"
        "            print(val)\n"
        "    except Exception:\n"
        "        try:\n"
        "            exec(code, globals())\n"
        "        except Exception as e:\n"
        "            import traceback\n"
        "            traceback.print_exc()\n"
        "    finally:\n"
        "        pass\n"
        "\n"
        "_applepye_run(__APPLEPYE_CODE__)\n"
        "result = _applepye_buf.getvalue()\n"
        "sys.stdout = _applepye_old_stdout\n"
        "sys.stderr = _applepye_old_stderr\n";

    // Build the final Python source by inserting the code as a repr (so quotes/newlines are safe)
    PyGILState_STATE gstate = PyGILState_Ensure();

    // Create a Python string containing the code (safely)
    PyObject* py_main = PyImport_AddModule("__main__");
    PyObject* py_dict = PyModule_GetDict(py_main);

    PyObject* py_code_obj = PyUnicode_FromString(code_c);
    if (!py_code_obj) {
        PyGILState_Release(gstate);
        return _dup_str("/* failed to create Python code string */");
    }

    // Prepare wrapper source with a substitution variable name __APPLEPYE_CODE__
    // We'll insert the code object into globals under that name, then run wrapper.
    if (PyDict_SetItemString(py_dict, "__APPLEPYE_CODE__", py_code_obj) != 0) {
        Py_DECREF(py_code_obj);
        PyGILState_Release(gstate);
        return _dup_str("/* failed to set __APPLEPYE_CODE__ */");
    }
    Py_DECREF(py_code_obj);

    // Run the wrapper
    int res = PyRun_SimpleString(wrapper);
    if (res != 0) {
        // Try to fetch any partial 'result' variable
    }

    // Retrieve 'result' variable from __main__
    PyObject* py_result = PyDict_GetItemString(py_dict, "result"); // borrowed ref
    char* out = NULL;
    if (py_result && PyUnicode_Check(py_result)) {
        const char* s = PyUnicode_AsUTF8(py_result);
        out = _dup_str(s ? s : "");
    } else {
        out = _dup_str("");
    }

    // Clean up the temporary keys we added (optional)
    PyDict_DelItemString(py_dict, "__APPLEPYE_CODE__");
    PyDict_DelItemString(py_dict, "result");

    PyGILState_Release(gstate);
    return out;
}
