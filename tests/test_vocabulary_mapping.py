"""Run with: python3 -m unittest discover -s tests

Exercise the production mapping queries on synthetic data using SQLite.
Only SQL Server's SELECT INTO, CONVERT and ISNULL syntax is adapted;
this does not replace a SQL Server integration test.
"""
from pathlib import Path
import re
import sqlite3
import unittest

SQL = (Path(__file__).resolve().parents[1] / 'MSSQL/OMOPLoader.sql').read_text()


class VocabularyMappingTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.addCleanup(self.db.close)
        self.db.executescript('''
            create table concept(concept_id integer, concept_code text,
                vocabulary_id text, domain_id text, standard_concept text,
                invalid_reason text);
            create table concept_relationship(concept_id_1 integer,
                concept_id_2 integer, relationship_id text);
            create table i2o_ontology_lab(i_stdcode text, i_stddomain text);
            create table i2o_ontology_drug(i_stdcode text, i_stddomain text);
        ''')

    def concept(self, id, code, vocab, domain='Drug', standard=None, invalid=None):
        self.db.execute('insert into concept values (?,?,?,?,?,?)',
                        (id, code, vocab, domain, standard, invalid))

    def maps_to(self, source, target):
        self.db.execute("insert into concept_relationship values (?,?,'Maps to')",
                        (source, target))

    def build(self):
        labs = SQL.split('-- Add labs from the ontology\n', 1)[1].split(';', 1)[0]
        labs = labs.replace('into i2o_mapping', '')
        labs = labs.replace('convert(int, c2.concept_id)', 'c2.concept_id')
        labs = labs.replace('convert(varchar(20),c2.domain_id)', 'c2.domain_id')
        self.db.execute('create table i2o_mapping as ' + labs)
        drugs = SQL.split(';with candidate_mappings as (', 1)[1].split('-- Index it', 1)[0]
        self.db.executescript('with candidate_mappings as (' + drugs.replace('isnull(', 'ifnull('))

    def rows(self):
        return set(self.db.execute('select source_vocabulary_id, source_id, concept_id from i2o_mapping'))

    def test_lab_collision_and_target_filters(self):
        self.db.execute("insert into i2o_ontology_lab values ('X','LOINC')")
        for id, vocab in [(1, 'LOINC'), (2, 'Other')]:
            self.concept(id, 'X', vocab, 'Measurement')
            self.concept(id + 10, str(id), 'LOINC', 'Measurement', 'S')
            self.maps_to(id, id + 10)
        self.concept(20, 'invalid', 'LOINC', 'Measurement', 'S', 'D')
        self.concept(21, 'nonstandard', 'LOINC', 'Measurement')
        self.maps_to(1, 20)
        self.maps_to(1, 21)
        self.build()
        self.assertEqual(self.rows(), {('LOINC', 1, 11)})
        # A foreign-vocabulary row must also be rejected by the lab consumer.
        self.db.execute("insert into i2o_mapping values ('X','Other',2,12,'Measurement')")
        join = re.search(r"inner join i2o_mapping omap on (lab.i_stdcode[^\n]+)", SQL).group(1)
        actual = list(self.db.execute('select omap.concept_id from i2o_ontology_lab lab '
                                     'inner join i2o_mapping omap on ' + join))
        self.assertEqual(actual, [(11,)])

    def test_drug_collision_through_consumer(self):
        for id, vocab in [(1, 'RxNorm'), (2, 'NDC'), (3, 'Other')]:
            self.concept(id, 'X', vocab)
            self.concept(id + 10, str(id), 'RxNorm', standard='S')
            self.maps_to(id, id + 10)
            self.db.execute('insert into i2o_ontology_drug values (?,?)', ('X', vocab))
        self.concept(14, 'second', 'RxNorm', standard='S')
        self.maps_to(1, 14)
        self.build()
        self.assertEqual(self.rows(), {('RxNorm', 1, 11), ('RxNorm', 1, 14), ('NDC', 2, 12)})
        join = re.search(r'left join i2o_mapping omap on ([^\n]+)', SQL).group(1)
        actual = set(self.db.execute('select mo.i_stddomain, omap.concept_id '
                     'from i2o_ontology_drug mo left join i2o_mapping omap on ' + join))
        self.assertEqual(actual, {('RxNorm', 11), ('RxNorm', 14), ('NDC', 12), ('Other', None)})

    def test_unmapped_source_not_suppressed_by_other_vocabulary(self):
        for id, vocab in [(1, 'RxNorm'), (2, 'NDC')]:
            self.concept(id, 'X', vocab)
            self.db.execute('insert into i2o_ontology_drug values (?,?)', ('X', vocab))
        self.concept(12, 'target', 'RxNorm', standard='S')
        self.maps_to(2, 12)
        self.build()
        self.assertEqual(self.rows(), {('RxNorm', 1, None), ('NDC', 2, 12)})


if __name__ == '__main__':
    unittest.main()
