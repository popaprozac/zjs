#include <stdio.h>
#include "zjs.h"

#define CHECK(cond) do { if (!(cond)) { printf("FAIL: %s\n", #cond); fails++; } } while (0)

int main(void) {
    int fails = 0;
    CHECK(zjs_is_int32(zjs_int32(42)));
    CHECK(zjs_as_int32(zjs_int32(42)) == 42);
    CHECK(zjs_as_int32(zjs_int32(-7)) == -7);
    CHECK(zjs_is_double(zjs_double(3.5)));
    CHECK(zjs_as_double(zjs_double(3.5)) == 3.5);
    CHECK(!zjs_is_int32(zjs_double(3.5)));
    CHECK(zjs_is_bool(zjs_bool(1)));
    CHECK(zjs_as_bool(zjs_bool(1)) == 1);
    CHECK(zjs_as_bool(zjs_bool(0)) == 0);
    CHECK(zjs_is_null(zjs_null()));
    CHECK(zjs_is_undefined(zjs_undefined()));
    CHECK(!zjs_is_number(zjs_null()));
    if (fails == 0) printf("cabi_smoke: all passed\n");
    return fails;
}
