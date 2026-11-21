# Design-tokens HR Monitor (web + iOS)

Bron: `index.html` (webapp, GSAP + Lenis). iOS (SwiftUI) neemt dezelfde waarden over.

## Kleuren
| Token | Hex | Gebruik |
|---|---|---|
| bg | `#050607` | achtergrond (altijd donker) |
| card | `#14171B` @ 72 % + blur 10 | tegels (`.ultraThinMaterial` op iOS) |
| card2 | `#111418` | knoppen, segment-control |
| line | wit @ 8 % | randen 1 px |
| fg | `#F2F4F6` | tekst |
| mut | `#8A939E` | labels, eenheden |
| ok / accent | `#00F19F` | verbonden, Whoop-groen |
| err | `#FF4D5E` | fout, opnemen |

Hartslagzones (% van HRmax, standaard 190, instelbaar):
| Zone | Grens | Hex |
|---|---|---|
| Rust | < 50 % | `#6B7280` |
| Z1 herstel | 50–60 % | `#3B82F6` |
| Z2 duur | 60–70 % | `#00F19F` |
| Z3 tempo | 70–80 % | `#FACC15` |
| Z4 drempel | 80–90 % | `#FB923C` |
| Z5 max | ≥ 90 % | `#FF4D5E` |

De actuele zonekleur (`--z`) kleurt ring, hartje, zonelabel, grafieklijn en de grootste aurora-vlek; overgang 0,8 s.

## Typografie
- Font: system (SF Pro op iOS), gewicht 800 voor de grote HR, 700 voor tegelwaarden.
- Cijfers altijd tabular (`.monospacedDigit()`).
- Grote HR: 84–148 pt, letter-spacing −4 %.
- Tegelwaarde: 30–40 pt; eenheid 14 pt, mut.
- Labels: 11–12 pt, HOOFDLETTERS, tracking 0,16–0,2 em, mut.

## Vorm en ruimte
- Radius: tegels 20, knoppen/pills 999 (capsule), inputs 10.
- Gutter 16, gap tussen tegels 14, sectiekop 56 boven / 14 onder.
- Ring: r = 116 op viewBox 260, lijndikte 14, round cap, glow (shadow 14 in zonekleur). Vulling = (HR − 40)/(HRmax − 40).

## Layout (dashboard)
1. Hero, scherm-hoog: ring met hartje, HR, "BPM", zonelabel, sensorcontact.
2. "Vandaag": tegels min/gem/max, RR, HRV (RMSSD 60 s), batterij, sessieduur. (iOS: plus huidtemperatuur.)
3. "Hartslag · laatste 5 min": lijn in zonekleur met verloopvulling (55 % → 0 %) en eindpunt.
4. "Tijd per zone": horizontale balken per zone met tijd m:ss.

## Beweging
| Element | Animatie | Duur / easing |
|---|---|---|
| Getallen | optellen naar nieuwe waarde | 0,6 s, power2.out (≈ `.easeOut`) |
| Ring | dashoffset naar nieuwe vulling | 0,9 s, power3.out |
| Hartje | puls 1 → 1,3 → 1 op het ritme van de HR | 0,12 s uit + 0,4 s terug per slag |
| Intro | ring schaal 0,85 → 1 + fade | 1,2 s, expo.out |
| Scroll | tegels 40 pt omhoog + fade, stagger 0,08 | 0,9 s, power3.out |
| Hero bij scrollen | ring schaal → 0,82, opacity → 0,35 | gekoppeld aan scrollpositie |
| Tabs | glijdende pill | 0,45 s, power3.out |
| Achtergrond | 3 wazige vlekken (blur 90) drijven | 9–15 s, sine.inOut, heen en weer |

`prefers-reduced-motion` (iOS: `accessibilityReduceMotion`) zet alle beweging uit.
