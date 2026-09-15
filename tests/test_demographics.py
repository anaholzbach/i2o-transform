"""Execute the production demographics UNION and its generated INSERTs on fixtures.

SQLite adaptations cover string concatenation, date helpers, and CONVERT.
The optional-column branches are selected using fixture metadata; SQL Server's
COL_LENGTH and stored-procedure compilation still require integration testing.
Run: python3 -B -m unittest discover -s tests
"""
from pathlib import Path
import re
import sqlite3
import unittest

SQL = (Path(__file__).resolve().parents[1] / 'MSSQL/OMOPLoader.sql').read_text()
GENERATOR = SQL.split('declare getsql cursor local for', 1)[1].split(
    '\nbegin\nexec pcornet_popcodelist', 1)[0]


def adapt(sql):
    # Preserve literals (including escaped quotes) at both dynamic SQL levels.
    tokens = re.findall(r"'(?:''|[^'])*'|--[^\n]*|[^'\-]+|.", sql)
    return ''.join(token if token.startswith("'") else '' if token.startswith('--')
                   else token.replace('+', '||') for token in tokens).replace('isnull(', 'ifnull(')


class DemographicsTest(unittest.TestCase):
    def database(self, has_ethnic_group):
        db = sqlite3.connect(':memory:')
        self.addCleanup(db.close)
        db.executescript('''
            create table pcornet_demo(c_fullname text, c_name text,
                c_visualattributes text, c_dimcode text, omop_basecode text);
            create table omop_codelist(codetype text, code text);
            create table patient_dimension(patient_num integer, sex_cd text,
                race_cd text, birth_date text);
            create table i2b2patient_list(patient_num integer);
            create table person(gender_source_value text, race_source_value text,
                ethnicity_source_value text, person_id integer primary key,
                year_of_birth integer, month_of_birth integer, day_of_birth integer,
                birth_datetime text, gender_concept_id integer,
                ethnicity_concept_id integer, race_concept_id integer);
        ''')
        if has_ethnic_group:
            db.execute('alter table patient_dimension add Ethnic_Group text')
        for name, part in [('year', 0), ('month', 1), ('day', 2)]:
            db.create_function(name, 1, lambda date, p=part: int(date.split('-')[p]))
        # Match SQL Server's default LTRIM/RTRIM behavior: trim spaces only.
        db.create_function('ltrim', 1, lambda s: None if s is None else s.lstrip(' '))
        db.create_function('rtrim', 1, lambda s: None if s is None else s.rstrip(' '))
        for category, suffix, name, codes, concept in [
            ('SEX', 'M', 'Male', ['m'], '8507'),
            ('SEX', 'F', 'Female', ['f'], '8532'),
            ('RACE', '05', 'White', ['white', 'his/white'], '8527'),
            ('RACE', '03', 'Black', ['black', 'his/black'], '8516'),
            ('HISPANIC', 'Y', 'Hispanic', ['hispanic', 'his/white', 'his/black'], '38003563'),
        ]:
            db.execute('insert into pcornet_demo values (?,?,?,?,?)',
                       ('\\PCORI\\DEMOGRAPHIC\\' + category + '\\' + suffix + '\\',
                        name, 'LAE', ','.join("'" + code + "'" for code in codes), concept))
            db.executemany('insert into omop_codelist values (?,?)', [(category, c) for c in codes])
        # Read both actual view projections from production, then select the
        # branch for a source table that physically has/does not have the column.
        projections = re.findall(r"SET @EthnicityColumns = N'((?:''|[^'])*)'", SQL)
        self.assertEqual(len(projections), 2)
        projection = projections[int(has_ethnic_group)].replace("''", "'")
        projection = re.sub(r'convert\(varchar\(50\), Ethnic_Group\)',
                            'substr(Ethnic_Group, 1, 50)', projection, flags=re.I)
        db.execute('create view i2b2patient as select *, ' + projection +
                   ' from patient_dimension where patient_num in (select patient_num from i2b2patient_list)')
        return db

    def add_patient(self, db, id, sex, race, *ethnic_group):
        values = (id, sex, race, '1980-01-02') + ethnic_group
        db.execute('insert into patient_dimension values (' + ','.join('?' for _ in values) + ')', values)
        db.execute('insert into i2b2patient_list values (?)', (id,))

    def run_transform(self, db, reverse=False):
        statements = [row[0] for row in db.execute(adapt(GENERATOR))]
        self.assertTrue(statements)
        self.assertTrue(all(s is not None and len(s) <= 4000 for s in statements))
        for statement in reversed(statements) if reverse else statements:
            db.execute(adapt(statement))

    def test_missing_column_preserves_legacy_results(self):
        db = self.database(False)
        expected = []
        for sex in ['M', 'F', 'unknown', None]:
            for race in ['white', 'black', 'his/white', 'his/black', 'hispanic', 'unknown', None]:
                id = len(expected) + 1
                self.add_patient(db, id, sex, race)
                expected.append((id, {'M': 8507, 'F': 8532}.get(sex, 0),
                                 38003563 if race in ['his/white', 'his/black', 'hispanic'] else 0,
                                 {'white': 8527, 'his/white': 8527, 'black': 8516, 'his/black': 8516}.get(race, 0)))
        self.run_transform(db)
        self.assertEqual(db.execute('select person_id,gender_concept_id,ethnicity_concept_id,race_concept_id '
                                    'from person order by person_id').fetchall(), expected)
        self.assertEqual(db.execute('select ethnicity_source_value from person where person_id=5').fetchone(),
                         ('hispanic:Hispanic',))
        self.run_transform(db, reverse=True)
        self.assertEqual(db.execute('select count(*) from person').fetchone()[0], len(expected))

    def test_present_column_overrides_every_union_branch(self):
        db = self.database(True)
        expected = []
        for sex in ['M', 'F', 'unknown', None]:
            for race in ['white', 'black', 'his/white', 'his/black', 'hispanic', 'unknown', None]:
                for ethnicity in ['HISPANIC', '  hIsPaNiC  ', 'NON-HISPANIC', '', '   ', None, "O'Brien", 'x' * 80]:
                    id = len(expected) + 1
                    self.add_patient(db, id, sex, race, ethnicity)
                    expected.append((id, {'M': 8507, 'F': 8532}.get(sex, 0),
                                     38003563 if ethnicity and ethnicity.strip().upper() == 'HISPANIC' else 0,
                                     {'white': 8527, 'his/white': 8527, 'black': 8516, 'his/black': 8516}.get(race, 0),
                                     None if ethnicity is None else ethnicity[:50]))
        self.run_transform(db, reverse=True)
        self.assertEqual(db.execute('select person_id,gender_concept_id,ethnicity_concept_id,race_concept_id,'
                                    'ethnicity_source_value from person order by person_id').fetchall(), expected)
        self.run_transform(db)
        self.assertEqual(db.execute('select count(*) from person').fetchone()[0], len(expected))

    def test_patient_selection_and_existing_people_preserved(self):
        db = self.database(True)
        self.add_patient(db, 1, 'M', 'white', 'HISPANIC')
        db.execute('delete from i2b2patient_list')
        self.run_transform(db)
        self.assertEqual(db.execute('select count(*) from person').fetchone()[0], 0)
        db.execute('insert into i2b2patient_list values (1)')
        db.execute('insert into person(person_id,ethnicity_concept_id) values (1,123)')
        self.run_transform(db)
        self.assertEqual(db.execute('select ethnicity_concept_id from person').fetchone()[0], 123)


if __name__ == '__main__':
    unittest.main()
