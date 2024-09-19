# Makefile for libarchive with elixir_make

# Configurable variables
LIBARCHIVE_VERSION := 3.7.5
DOWNLOAD_DIR := $(MIX_BUILD_PATH)
BUILD_DIR := $(MIX_BUILD_PATH)

# URLs and filenames
LIBARCHIVE_URL := https://github.com/libarchive/libarchive/releases/download/v$(LIBARCHIVE_VERSION)/libarchive-$(LIBARCHIVE_VERSION).tar.gz
LIBARCHIVE_TARBALL := $(DOWNLOAD_DIR)/libarchive-$(LIBARCHIVE_VERSION).tar.gz
LIBARCHIVE_SRC_DIR := $(BUILD_DIR)/libarchive-$(LIBARCHIVE_VERSION)

# Check if libarchive is already installed
LIBARCHIVE_INSTALLED := $(shell [ -f "$(MIX_APP_PATH)/priv/$(MIX_TARGET)/lib/libarchive.a" ] && echo "yes" || echo "no")

# Default target
all: libarchive

# Download libarchive
$(LIBARCHIVE_TARBALL):
	@echo "Downloading libarchive..."
	mkdir -p $(DOWNLOAD_DIR)
	curl -L -o $@ $(LIBARCHIVE_URL) || (rm -f $@ && exit 1)
	@echo "Download completed."

# Extract libarchive
$(LIBARCHIVE_SRC_DIR): $(LIBARCHIVE_TARBALL)
	@echo "Extracting libarchive..."
	mkdir -p $(BUILD_DIR)
	tar -xzf $< -C $(BUILD_DIR) || (rm -rf $(LIBARCHIVE_SRC_DIR) && exit 1)
	@echo "Extraction completed."

# Build and install libarchive
libarchive: $(LIBARCHIVE_SRC_DIR)
ifeq ($(LIBARCHIVE_INSTALLED),no)
	@echo "Building libarchive..."
	cd $(LIBARCHIVE_SRC_DIR) && \
	./configure --prefix=$(MIX_APP_PATH)/priv/$(MIX_TARGET) --disable-bsdtar --disable-bsdcpio && \
	make && \
	make install
	@echo "Build and installation completed."
else
	@echo "libarchive is already installed. Skipping build."
endif

# Clean up
clean:
	rm -rf $(BUILD_DIR)/libarchive-*
	rm -rf $(MIX_APP_PATH)/priv/lib $(MIX_APP_PATH)/priv/include

.PHONY: all libarchive clean
