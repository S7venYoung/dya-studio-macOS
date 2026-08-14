import {
  pathnameFromTabId,
  tabIdFromLocation,
  tabIdFromPathname,
} from "../useUrlTab";

describe("URL tab routing", () => {
  it("uses the keymap tab for the app root", () => {
    expect(tabIdFromPathname("/")).toBe("keymap");
    expect(pathnameFromTabId("keymap")).toBe("/");
  });

  it("keeps explicit tab paths working", () => {
    expect(tabIdFromPathname("/keymap")).toBe("keymap");
    expect(tabIdFromPathname("/settings")).toBe("settings");
    expect(pathnameFromTabId("settings")).toBe("/settings");
  });

  it("uses hash routing for a file-based macOS app", () => {
    expect(
      tabIdFromLocation({
        protocol: "file:",
        pathname: "/Applications/DYA Studio.app/Contents/Resources/dist/index.html",
        hash: "",
      } as Location),
    ).toBe("keymap");

    expect(
      tabIdFromLocation({
        protocol: "file:",
        pathname: "/Applications/DYA Studio.app/Contents/Resources/dist/index.html",
        hash: "#/settings",
      } as Location),
    ).toBe("settings");
  });
});
