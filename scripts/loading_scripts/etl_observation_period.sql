/* Observation period for each person.
    Hard coded parameters: data cut start = 19970101, data cut end = 20150801.
    Fails if emigration before start of datacut and no immigration (unlikely event)
*/
INSERT INTO observation_period (
        person_id,
        observation_period_start_date,
        observation_period_end_date,
        period_type_concept_id
)
SELECT  person_id,

        -- 2016-10-11 Just take start and end of study as observation period
        to_date(:'data_start_date','yyyymmdd'), -- 19970101
        to_date(:'data_end_date','yyyymmdd'), -- 20150801
        44814724 AS period_type_concept_id -- 'Period covering healthcare encounters'

        -- getObservationStartDate( to_date(:'data_start_date','yyyymmdd'), year_of_birth, immi_date, emi_date ) as observation_period_start_date,
        -- getObservationEndDate( to_date(:'data_end_date','yyyymmdd'), death_date, immi_date, emi_date ) as observation_period_end_date,
        -- 44814725 AS period_type_concept_id -- 'Period inferred by algorithm'

    FROM (
        SELECT person.person_id,
               to_date(person.year_of_birth::varchar, 'yyyymmdd') as year_of_birth,
               death.death_date,
               -- '1997' is converted by to_date to 01-01-1997
               to_date(seninv, 'yyyymmdd') as immi_date,
               to_date(senutv, 'yyyymmdd') as emi_date
        FROM person as person
        LEFT JOIN etl_input.lpnr_aggregated as emmigration
          ON person.person_id = emmigration.lpnr
        LEFT JOIN death as death
          ON person.person_id = death.person_id
    ) A
;
