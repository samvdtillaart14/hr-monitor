# Werkwijze voor Claude

Gebruiker: Sam, werktuigbouwkundig ingenieur, geen developer. Antwoord in het Nederlands, kort.

## Zuinig werken
- Lees alleen de bestanden die voor deze taak nodig zijn. Niet de hele map `docs/` doorlezen.
- Lees nooit `testdata/`, `scores/test/fixtures/` of `vendor/` (grote data/bibliotheken).
- Eén taak per gesprek.

## Werkwijze
1. Haal eerst de nieuwste `main` op en check of een open `claude/`-branch dezelfde bestanden raakt; waarschuw zo ja.
2. Geef een kort plan en wacht op akkoord.
3. Werk op een nieuwe branch die begint met `claude/`. Push nooit naar `main` en merge niet zelf.
4. Bouwen en testen gebeurt op GitHub (deze Windows-pc kan geen Swift bouwen). Merge pas als **Tests** en **iOS build** groen zijn.
5. Geef de pull-request-link en wat Sam op de iPhone moet testen (zie `docs/HANDMATIGE-TESTS.md`).

## Privacy
De repo is openbaar: zet nooit gezondheidsdata, serienummers of persoonsgegevens in de repo.
