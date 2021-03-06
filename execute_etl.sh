#!/bin/sh
# Created by Maxim Moinat.
# Copyright (c) 2016 The Hyve B.V.
# This code is licensed under the Apache License version 2.0

# Command line Variables
DATABASE_NAME="$1"
USER="$2"
ENCODING="$3"
DATABASE_SCHEMA="$4"
VOCAB_SCHEMA="$5"

# ETL parameters
DATA_START_DATE="19970101"
DATA_END_DATE="20150801"
# Source daimon parameters
DATASET_NAME="Swedish Registry ETL $DATE"
DATASET_ABBREV="SwedReg"
WEBAPI_SCHEMA="webapi" #Schema of source an source_daimon tables and results tables
CONNECTION_STRING="jdbc:postgresql://localhost:5432/ohdsi?user=webapi&password=webapi"
PRIO_DAIMONS=1

# System Constants
SCRIPTS_FOLDER="scripts"
SOURCE_FOLDER="source_tables"
MAP_SCRIPT_FOLDER="$SCRIPTS_FOLDER/mapping_scripts"
ETL_SCRIPT_FOLDER="$SCRIPTS_FOLDER/loading_scripts"
DYNAMIC_SCRIPT_FOLDER="$SCRIPTS_FOLDER/rendered_sql"
SQL_FUNCTIONS_FOLDER="$SCRIPTS_FOLDER/sql_functions"
PYTHON_FOLDER="$SCRIPTS_FOLDER/python"
DRUG_MAPPING_FOLDER="$SCRIPTS_FOLDER/drug_mapping"
OMOP_CDM_FOLDER="$SCRIPTS_FOLDER/OMOPCDM"
TIME_FORMAT="Elapsed Time: %e sec"
DATE=`date +%Y-%m-%d_%H:%M`

# Check whether command line arguments are given
if [ "$DATABASE_NAME" = "" ] || [ "$USER" = "" ]; then
    echo "Please input a database name and username of the database. Usage: "
    echo "./execute_etl.sh <database_name> <user_name> [<encoding>] [<database_schema>] [<vocabulary_schema>]"
    exit 1
fi
# Defaults
if [ "$ENCODING" = "" ]; then ENCODING="UTF8"; fi
if [ "$DATABASE_SCHEMA" = "" ]; then DATABASE_SCHEMA="cdm5"; fi
if [ "$VOCAB_SCHEMA" = "" ]; then VOCAB_SCHEMA="cdm5"; fi

date
echo "===== Starting the ETL procedure to OMOP CDM ====="
echo "Using the database '$DATABASE_NAME' and the '$DATABASE_SCHEMA' schema."
echo "Loading source files from the folder '$SOURCE_FOLDER' "
echo "Using $ENCODING encoding of the source files."

# Create cdm5 schema. Assume vocab schema exists and is filled.
sudo -u $USER psql -d $DATABASE_NAME -c "CREATE SCHEMA IF NOT EXISTS $DATABASE_SCHEMA;"
# Search for tables in database schema, if schema name not specified explicitly.
sudo -u $USER psql -d $DATABASE_NAME -c "ALTER DATABASE $DATABASE_NAME SET search_path TO $DATABASE_SCHEMA;"

echo
echo "Preprocessing patient registers..."
# First remove any existing rendered tables
rm -f rendered_tables/patient_register/*
rm -f rendered_tables/death_register/*
python3 $PYTHON_FOLDER/process_patient_tables_wide_to_long.py $SOURCE_FOLDER $ENCODING
python3 $PYTHON_FOLDER/process_death_tables_wide_to_long.py $SOURCE_FOLDER $ENCODING
echo
echo "Reading headers of source tables..."
# python $SCRIPTS_FOLDER/process_drug_registries.py $SOURCE_FOLDER/drug_register
python3 $PYTHON_FOLDER/create_copy_sql.py $SOURCE_FOLDER $ENCODING $DYNAMIC_SCRIPT_FOLDER

echo
# The following is executed quietly (-q)
echo "Dropping cdm5 tables and emptying schemas..."
sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/empty_schemas.sql -q
sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/drop_cdm_tables.sql -q
sudo -u $USER psql -d $DATABASE_NAME -f "$OMOP_CDM_FOLDER/OMOP CDM ddl.sql" -q
echo "Creating sequences..."
sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/alter_omop_cdm.sql -q

echo
echo "Creating source tables..."
sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/create_source_tables.sql

echo "Loading source tables..."
# sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/load_source_tables.sql
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $DYNAMIC_SCRIPT_FOLDER/load_tables.sql
echo "Filtering rows without date..."
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/filter_source_tables.sql
echo "Creating indices source tables..."
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/alter_source_tables.sql

# Search for tables first in database schema, then in vocabulary schema (and last in public schema)
sudo -u $USER psql -d $DATABASE_NAME -c "ALTER DATABASE $DATABASE_NAME SET search_path TO $DATABASE_SCHEMA, $VOCAB_SCHEMA, public;"

echo
echo "Creating mapping tables..."
sudo -u $USER psql -d $DATABASE_NAME -f $MAP_SCRIPT_FOLDER/load_mapping_tables.sql
echo "Loading mappings into the source_to_concept_map:"
sudo -u $USER psql -d $DATABASE_NAME -f $MAP_SCRIPT_FOLDER/load_source_to_concept_map.sql

echo
echo "Preprocessing..."
printf "%-35s" "Unique persons from registers: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/lpnr_aggregated.sql
echo "Create supporting SQL functions:"
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/getObservationStartDate.sql
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/getObservationEndDate.sql
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/convertDeathDate.sql
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/getDrugQuantity.sql
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/getDrugEndDate.sql
sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/getDrugDaysSupply.sql

# Actual ETL. Order is important.
# Especially always first Person and Death tables.
echo
echo "Performing ETL..."
printf "%-35s" "Person: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_person.sql
printf "%-35s" "Death with addendum table: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_death.sql
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_death_addendum.sql -q
printf "%-35s" "Observation Period: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_period.sql -v data_start_date=$DATA_START_DATE -v data_end_date=$DATA_END_DATE
printf "%-35s" "Visit Occurrence: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_visit_occurrence.sql

printf "%-35s" "Condition Occurrence: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_condition_occurrence.sql
printf "%-35s" "Procedure Occurrence: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_procedure_occurrence.sql
printf "%-35s" "Drug Exposure: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_drug_exposure.sql

printf "%-35s" "Observation Death Morsak: " #Additional causes of death
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_death.sql
printf "%-35s" "Observation Civil Status: " #Only where civil is not null
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_civil.sql
printf "%-35s" "Observation Planned visit: " #all
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_pvard.sql
printf "%-35s" "Observation Utsatt Status: " #Only sluten care
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_utsatt.sql
printf "%-35s" "Observation Insatt Status: " #Only sluten care
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_insatt.sql
printf "%-35s" "Observation Ekod: "          #Only where ekod is not null
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_ekod.sql
printf "%-35s" "Observation Work Status: "       #Only Lisa
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_work_status.sql
printf "%-35s" "Observation Education level: "   #Only Lisa
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_education.sql
printf "%-35s" "Observation Ethnic Background: " #Only Lisa
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_observation_background.sql


printf "%-35s" "Measurement Income: " #Only Lisa
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_measurement_income.sql
# printf "%-35s" "Measurement Age: " #All registers
# time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/etl_measurement_age.sql

echo
echo "Building Eras..."
printf "%-35s" "Condition Era: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/build_condition_era.sql
printf "%-35s" "Drug Era: "
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f $ETL_SCRIPT_FOLDER/build_drug_era.sql

# Insert data information in cdm_source and webapi_sourc[_daimon] tables
echo
sudo -u $USER psql -d $DATABASE_NAME -f $SCRIPTS_FOLDER/insert_cdm_source.sql -q -v source_release_date=$DATA_END_DATE
# 26-08-2016: do not set the source daimon. Leads to confusion if same schema is used multiple times (looks like new database is added, while it is overwritten)
# sudo -u $USER psql -d $DATABASE_NAME -f $SQL_FUNCTIONS_FOLDER/setSourceDaimon.sql
# echo "The new Source ID is:"
# sudo -u $USER psql -d $DATABASE_NAME -c "SELECT setSourceDaimon('$DATABASE_SCHEMA','Swedish Registry ETL $DATE','SwedReg');" -t

# Grant access to webapi in order to make the person tab work
sudo -u $USER psql -d $DATABASE_NAME -c "GRANT SELECT ON ALL TABLES IN SCHEMA $DATABASE_SCHEMA TO webapi;"
sudo -u $USER psql -d $DATABASE_NAME -c "GRANT USAGE ON SCHEMA $DATABASE_SCHEMA TO webapi;"

echo
echo "Adding constraints..."
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f "$OMOP_CDM_FOLDER/OMOP CDM constraints.sql" -q
echo "Adding indices..."
time -f "$TIME_FORMAT" sudo -u $USER psql -d $DATABASE_NAME -f "$OMOP_CDM_FOLDER/OMOP CDM indexes required.sql" -q

# Restore search path
sudo -u $USER psql -d $DATABASE_NAME -c "ALTER DATABASE $DATABASE_NAME SET search_path TO \"\$user\", public;"
date
