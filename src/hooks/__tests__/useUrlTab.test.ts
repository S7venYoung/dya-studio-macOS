import { pathnameFromTabId, tabIdFromPathname } from "../useUrlTab";

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
});
