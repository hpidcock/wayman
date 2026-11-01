// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

/* Every C header wayman uses, translated once by the build system into the "c" module. */
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/eventfd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <linux/input-event-codes.h>

#include <wayland-client.h>
#include <wayland-cursor.h>
#include <xdg-shell-client-protocol.h>
#include <viewporter-client-protocol.h>
#include <primary-selection-unstable-v1-client-protocol.h>
#include <poll.h>
#include <wlr-layer-shell-unstable-v1-client-protocol.h>
#include <xkbcommon/xkbcommon.h>

#include <cairo.h>
#include <pango/pangocairo.h>

#include <dbus/dbus.h>
