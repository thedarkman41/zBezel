// Bridging header for the Swift target.
// Exposes the C DDC transport plus the IOKit graphics calls that are not part of
// IOKit's Swift module map.
#ifndef BEZEL_BRIDGING_H
#define BEZEL_BRIDGING_H

#include "ddc.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>

#endif
