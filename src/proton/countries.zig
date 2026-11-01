// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! ISO 3166-1 alpha-2 codes to English names, for the country picker.
const std = @import("std");

const Entry = struct { code: *const [2]u8, name: []const u8 };

const table = [_]Entry{
    .{ .code = "AD", .name = "Andorra" },                .{ .code = "AE", .name = "United Arab Emirates" },
    .{ .code = "AL", .name = "Albania" },                .{ .code = "AM", .name = "Armenia" },
    .{ .code = "AR", .name = "Argentina" },              .{ .code = "AT", .name = "Austria" },
    .{ .code = "AU", .name = "Australia" },              .{ .code = "AZ", .name = "Azerbaijan" },
    .{ .code = "BA", .name = "Bosnia and Herzegovina" }, .{ .code = "BD", .name = "Bangladesh" },
    .{ .code = "BE", .name = "Belgium" },                .{ .code = "BG", .name = "Bulgaria" },
    .{ .code = "BH", .name = "Bahrain" },                .{ .code = "BR", .name = "Brazil" },
    .{ .code = "BS", .name = "Bahamas" },                .{ .code = "BY", .name = "Belarus" },
    .{ .code = "CA", .name = "Canada" },                 .{ .code = "CH", .name = "Switzerland" },
    .{ .code = "CL", .name = "Chile" },                  .{ .code = "CO", .name = "Colombia" },
    .{ .code = "CR", .name = "Costa Rica" },             .{ .code = "CY", .name = "Cyprus" },
    .{ .code = "CZ", .name = "Czechia" },                .{ .code = "DE", .name = "Germany" },
    .{ .code = "DK", .name = "Denmark" },                .{ .code = "DZ", .name = "Algeria" },
    .{ .code = "EC", .name = "Ecuador" },                .{ .code = "EE", .name = "Estonia" },
    .{ .code = "EG", .name = "Egypt" },                  .{ .code = "ES", .name = "Spain" },
    .{ .code = "FI", .name = "Finland" },                .{ .code = "FR", .name = "France" },
    .{ .code = "GB", .name = "United Kingdom" },         .{ .code = "GE", .name = "Georgia" },
    .{ .code = "GH", .name = "Ghana" },                  .{ .code = "GR", .name = "Greece" },
    .{ .code = "HK", .name = "Hong Kong" },              .{ .code = "HR", .name = "Croatia" },
    .{ .code = "HU", .name = "Hungary" },                .{ .code = "ID", .name = "Indonesia" },
    .{ .code = "IE", .name = "Ireland" },                .{ .code = "IL", .name = "Israel" },
    .{ .code = "IN", .name = "India" },                  .{ .code = "IS", .name = "Iceland" },
    .{ .code = "IT", .name = "Italy" },                  .{ .code = "JP", .name = "Japan" },
    .{ .code = "KE", .name = "Kenya" },                  .{ .code = "KH", .name = "Cambodia" },
    .{ .code = "KR", .name = "South Korea" },            .{ .code = "KZ", .name = "Kazakhstan" },
    .{ .code = "LT", .name = "Lithuania" },              .{ .code = "LU", .name = "Luxembourg" },
    .{ .code = "LV", .name = "Latvia" },                 .{ .code = "MA", .name = "Morocco" },
    .{ .code = "MD", .name = "Moldova" },                .{ .code = "ME", .name = "Montenegro" },
    .{ .code = "MK", .name = "North Macedonia" },        .{ .code = "MM", .name = "Myanmar" },
    .{ .code = "MT", .name = "Malta" },                  .{ .code = "MU", .name = "Mauritius" },
    .{ .code = "MX", .name = "Mexico" },                 .{ .code = "MY", .name = "Malaysia" },
    .{ .code = "NG", .name = "Nigeria" },                .{ .code = "NL", .name = "Netherlands" },
    .{ .code = "NO", .name = "Norway" },                 .{ .code = "NP", .name = "Nepal" },
    .{ .code = "NZ", .name = "New Zealand" },            .{ .code = "PE", .name = "Peru" },
    .{ .code = "PH", .name = "Philippines" },            .{ .code = "PK", .name = "Pakistan" },
    .{ .code = "PL", .name = "Poland" },                 .{ .code = "PR", .name = "Puerto Rico" },
    .{ .code = "PT", .name = "Portugal" },               .{ .code = "QA", .name = "Qatar" },
    .{ .code = "RO", .name = "Romania" },                .{ .code = "RS", .name = "Serbia" },
    .{ .code = "RU", .name = "Russia" },                 .{ .code = "RW", .name = "Rwanda" },
    .{ .code = "SA", .name = "Saudi Arabia" },           .{ .code = "SE", .name = "Sweden" },
    .{ .code = "SG", .name = "Singapore" },              .{ .code = "SI", .name = "Slovenia" },
    .{ .code = "SK", .name = "Slovakia" },               .{ .code = "SN", .name = "Senegal" },
    .{ .code = "TH", .name = "Thailand" },
    .{ .code = "TR", .name = "Türkiye" },
    .{ .code = "TW", .name = "Taiwan" },                 .{ .code = "UA", .name = "Ukraine" },
    .{ .code = "UK", .name = "United Kingdom" },         .{ .code = "US", .name = "United States" },
    .{ .code = "UY", .name = "Uruguay" },                .{ .code = "VE", .name = "Venezuela" },
    .{ .code = "VN", .name = "Vietnam" },                .{ .code = "ZA", .name = "South Africa" },
    .{ .code = "AO", .name = "Angola" },                 .{ .code = "BT", .name = "Bhutan" },
    .{ .code = "BN", .name = "Brunei" },                 .{ .code = "CM", .name = "Cameroon" },
    .{ .code = "ET", .name = "Ethiopia" },               .{ .code = "GT", .name = "Guatemala" },
    .{ .code = "HN", .name = "Honduras" },               .{ .code = "JO", .name = "Jordan" },
    .{ .code = "KW", .name = "Kuwait" },                 .{ .code = "LA", .name = "Laos" },
    .{ .code = "LK", .name = "Sri Lanka" },              .{ .code = "MN", .name = "Mongolia" },
    .{ .code = "MZ", .name = "Mozambique" },             .{ .code = "NI", .name = "Nicaragua" },
    .{ .code = "OM", .name = "Oman" },                   .{ .code = "PA", .name = "Panama" },
    .{ .code = "PY", .name = "Paraguay" },               .{ .code = "SV", .name = "El Salvador" },
    .{ .code = "TN", .name = "Tunisia" },                .{ .code = "TZ", .name = "Tanzania" },
    .{ .code = "UG", .name = "Uganda" },                 .{ .code = "UZ", .name = "Uzbekistan" },
    .{ .code = "BO", .name = "Bolivia" },                .{ .code = "DO", .name = "Dominican Republic" },
    .{ .code = "IQ", .name = "Iraq" },                   .{ .code = "LB", .name = "Lebanon" },
    .{ .code = "MK", .name = "North Macedonia" },        .{ .code = "NA", .name = "Namibia" },
    .{ .code = "TG", .name = "Togo" },                   .{ .code = "ZM", .name = "Zambia" },
};

/// The English name for a code, or the code itself when unknown.
pub fn name(code: []const u8) []const u8 {
    if (code.len != 2) return code;
    var upper: [2]u8 = .{ std.ascii.toUpper(code[0]), std.ascii.toUpper(code[1]) };
    for (table) |e| {
        if (std.mem.eql(u8, e.code, &upper)) return e.name;
    }
    return code;
}

test "country names" {
    try std.testing.expectEqualStrings("Switzerland", name("CH"));
    try std.testing.expectEqualStrings("Switzerland", name("ch"));
    try std.testing.expectEqualStrings("XX", name("XX"));
}
