#include <VulkanApp.h>

static const uint F = 1u;

int main(int argc, char** argv) {
    VulkanApp<F> app(256, 240);
    app.init();
    return 0;
}