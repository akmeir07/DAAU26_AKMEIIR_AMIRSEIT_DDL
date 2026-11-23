-- SQL_DDL_Func homework, tasks 1-5
-- I put all new objects in schema core, like in the examples from the task.
-- Tables are in public, so I write public.table_name everywhere. Then the code
-- works even if search_path is different.
-- The file can be run many times without errors. Tests are in comments so a
-- second run does not insert test rows again.

CREATE SCHEMA IF NOT EXISTS core;


-- Task 1. View sales_revenue_by_category_qtr

/*
I go from payment to category: payment, rental, inventory, film_category, category.
Every payment is for one rental, so this way each payment gets the category of its film.
Then I just sum amount by category.

For the current quarter I use date_trunc('quarter', CURRENT_DATE). It gives the first
day of the quarter, for example 2026-10-01 for today. The quarter ends 3 months later.
This date already has the year in it, so I do not need a separate check for the year.
A payment from Q4 2025 will not pass, because it is before 2026-10-01.
CURRENT_DATE changes by itself, so when Q1 2027 starts the view will show Q1 2027.

I compare payment_date with a range and not EXTRACT(QUARTER FROM payment_date),
because with a range PostgreSQL can use an index on payment_date.
*/
-- INNER JOIN starts from payment, so a category without payments in this quarter
-- has nothing to join with and is not shown. HAVING > 0 also removes a category
-- whose payments sum to 0.
CREATE OR REPLACE VIEW core.sales_revenue_by_category_qtr AS
SELECT
    c.name        AS category,
    SUM(p.amount) AS total_revenue
FROM public.payment AS p
INNER JOIN public.rental        AS r  ON r.rental_id    = p.rental_id
INNER JOIN public.inventory     AS i  ON i.inventory_id = r.inventory_id
INNER JOIN public.film_category AS fc ON fc.film_id     = i.film_id
INNER JOIN public.category      AS c  ON c.category_id  = fc.category_id
WHERE p.payment_date >= date_trunc('quarter', CURRENT_DATE)
  AND p.payment_date <  date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months'
GROUP BY c.name
HAVING SUM(p.amount) > 0;

/*
Data that should NOT be in the view (if today is in Q4 2026):
a payment from 2026-09-30, because it is Q3.
a payment from 2025-11-10, because it is the same quarter but last year.
category Music, if nobody paid for a Music film in Q4 2026.

The database has no payments for this year, so now the view is empty, and that is ok.
I could not just add a test payment for today, because payment is a partitioned table
and there is no partition for this year, so the insert fails.
So I checked it another way. The function from task 2 has the same logic. I ran it with
the date of the last payment and got rows, then I checked them with a simple query
for the same quarter, the result was the same (test 2 gives 0 rows).
Then I checked that the view and the function with today's date give the same result.

Test 1, normal call:
SELECT * FROM core.sales_revenue_by_category_qtr;

Test 2, the function for the last quarter with data compared with a manual query.
0 rows means both give the same numbers:
SELECT * FROM core.get_sales_revenue_by_category_qtr((SELECT MAX(payment_date)::DATE FROM public.payment))
EXCEPT
SELECT c.name, SUM(p.amount)
FROM public.payment AS p
INNER JOIN public.rental        AS r  ON r.rental_id    = p.rental_id
INNER JOIN public.inventory     AS i  ON i.inventory_id = r.inventory_id
INNER JOIN public.film_category AS fc ON fc.film_id     = i.film_id
INNER JOIN public.category      AS c  ON c.category_id  = fc.category_id
WHERE date_trunc('quarter', p.payment_date) = (SELECT date_trunc('quarter', MAX(payment_date)) FROM public.payment)
GROUP BY c.name;

Test 3, the view and the function for today must match, 0 rows means they match:
SELECT * FROM core.sales_revenue_by_category_qtr
EXCEPT
SELECT * FROM core.get_sales_revenue_by_category_qtr();

The view has no parameters, so wrong input is not possible here.
If there is no data for the quarter, it just returns 0 rows.
*/


-- Task 2. Query language function get_sales_revenue_by_category_qtr

/*
The view can only look at today, and today has no data. So I need a parameter to
ask about any quarter. The parameter is any date inside the quarter. For example
'2017-05-14' means Q2 2017. I took a date because it holds the quarter and the year
in one value, and PostgreSQL checks dates by itself.

Default is CURRENT_DATE, so the function with no parameter returns the same as the view.
If someone passes NULL, COALESCE turns it into CURRENT_DATE.

A wrong quarter cannot even get into the function. '2017-13-01' gives the error
"date/time field value out of range" before the function starts. This is a plain
SQL function, so RAISE EXCEPTION is not available here, the date type does the check.
If the quarter has no payments, the result is just empty.
*/
CREATE OR REPLACE FUNCTION core.get_sales_revenue_by_category_qtr(
    p_quarter_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (category TEXT, total_revenue NUMERIC)
LANGUAGE sql
STABLE
AS $$
    SELECT
        c.name::TEXT,
        SUM(p.amount)
    FROM public.payment AS p
    INNER JOIN public.rental        AS r  ON r.rental_id    = p.rental_id
    INNER JOIN public.inventory     AS i  ON i.inventory_id = r.inventory_id
    INNER JOIN public.film_category AS fc ON fc.film_id     = i.film_id
    INNER JOIN public.category      AS c  ON c.category_id  = fc.category_id
    WHERE p.payment_date >= date_trunc('quarter', COALESCE(p_quarter_date, CURRENT_DATE))
      AND p.payment_date <  date_trunc('quarter', COALESCE(p_quarter_date, CURRENT_DATE)) + INTERVAL '3 months'
    GROUP BY c.name
    HAVING SUM(p.amount) > 0
    ORDER BY SUM(p.amount) DESC;
$$;

/*
Test 1. I take the date of the last payment, so I do not hardcode a year and
the quarter surely has data. It should return categories with revenue.
SELECT *
FROM core.get_sales_revenue_by_category_qtr(
         (SELECT MAX(payment_date)::DATE FROM public.payment));

Test 2. No parameter, should be the same as the view (empty on this database).
SELECT * FROM core.get_sales_revenue_by_category_qtr();

Test 3. Quarter with no data, returns 0 rows without error.
SELECT * FROM core.get_sales_revenue_by_category_qtr('1990-01-01');

Test 4. Month 13 does not exist, PostgreSQL gives an error.
SELECT * FROM core.get_sales_revenue_by_category_qtr('2017-13-01');
*/


-- Task 3. Procedure language function most_popular_films_by_countries

/*
Most popular means the film with the most rentals by customers from that country.
I did not use revenue because price is different for films, and a more expensive
film could win with fewer people watching it. The country of a customer comes from
customer, address, city, country.

If two films have the same number of rentals, I take the one that comes first
by title (A before B). So one country always gives one film and the answer
does not change between runs. DISTINCT ON with ORDER BY does this.

If a country is not in the table, or its customers never rented anything,
I show a NOTICE and skip it. The other countries still work.
If the array is NULL or empty there is nothing to search, so RAISE EXCEPTION.
Names are compared in lower case without spaces, so 'brazil' works too.
*/
CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(
    p_countries TEXT[]
)
RETURNS TABLE (
    "Country"      TEXT,
    "Film"         TEXT,
    "Rating"       TEXT,
    "Language"     TEXT,
    "Length"       INTEGER,
    "Release year" INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_country TEXT;
BEGIN
    IF p_countries IS NULL OR cardinality(p_countries) = 0 THEN
        RAISE EXCEPTION 'Please pass at least one country, for example: array[''Brazil'']';
    END IF;

    -- this loop only gives messages for countries that will not have a result
    FOREACH v_country IN ARRAY p_countries LOOP
        IF v_country IS NULL OR TRIM(v_country) = '' THEN
            RAISE NOTICE 'An empty country name was skipped';
        ELSIF NOT EXISTS (
            SELECT 1
            FROM public.country AS co
            WHERE LOWER(co.country) = LOWER(TRIM(v_country))
        ) THEN
            RAISE NOTICE 'Country "%" was not found in the country table', v_country;
        ELSIF NOT EXISTS (
            SELECT 1
            FROM public.country  AS co
            INNER JOIN public.city     AS ci ON ci.country_id = co.country_id
            INNER JOIN public.address  AS a  ON a.city_id     = ci.city_id
            INNER JOIN public.customer AS cu ON cu.address_id = a.address_id
            INNER JOIN public.rental   AS r  ON r.customer_id = cu.customer_id
            WHERE LOWER(co.country) = LOWER(TRIM(v_country))
        ) THEN
            RAISE NOTICE 'Country "%" has no rentals, so there is no popular film', v_country;
        END IF;
    END LOOP;

    -- count rentals for every country and film, then keep only the top film per country
    RETURN QUERY
    WITH film_rentals AS (
        SELECT
            co.country         AS country_name,
            i.film_id          AS film_id,
            COUNT(r.rental_id) AS rental_count
        FROM public.country  AS co
        INNER JOIN public.city      AS ci ON ci.country_id  = co.country_id
        INNER JOIN public.address   AS a  ON a.city_id      = ci.city_id
        INNER JOIN public.customer  AS cu ON cu.address_id  = a.address_id
        INNER JOIN public.rental    AS r  ON r.customer_id  = cu.customer_id
        INNER JOIN public.inventory AS i  ON i.inventory_id = r.inventory_id
        WHERE LOWER(co.country) IN (
            SELECT LOWER(TRIM(x)) FROM unnest(p_countries) AS x
        )
        GROUP BY co.country, i.film_id
    )
    SELECT DISTINCT ON (fr.country_name)
        fr.country_name::TEXT,
        f.title::TEXT,
        f.rating::TEXT,
        TRIM(l.name)::TEXT,
        f.length::INTEGER,
        f.release_year::INTEGER
    FROM film_rentals AS fr
    INNER JOIN public.film     AS f ON f.film_id     = fr.film_id
    INNER JOIN public.language AS l ON l.language_id = f.language_id
    ORDER BY fr.country_name, fr.rental_count DESC, f.title;
END;
$$;

/*
Test 1, normal input, gives one film for each country:
SELECT * FROM core.most_popular_films_by_countries(array['Afghanistan','Brazil','United States']);

Test 2, lower case name and a country that does not exist.
Brazil still returns a row, and for Narnia there is a NOTICE:
SELECT * FROM core.most_popular_films_by_countries(array['brazil', 'Narnia']);

Test 3, empty array, gives an error:
SELECT * FROM core.most_popular_films_by_countries(array[]::TEXT[]);
*/


-- Task 4. Procedure language function films_in_stock_by_title

/*
LIKE compares text with a pattern, and % means any text, even empty.
So '%love%' finds titles with "love" anywhere: LOVELY FILM, FILM LOVE, and also
GLOVE STORY, because glove has love inside. If the user writes just 'love'
without %, I add % on both sides, so the search still works.

I use ILIKE, it does not care about big or small letters. Titles in the database
are in capital letters, so with normal LIKE '%love%' would find nothing.

A film is in stock if at least one copy has no open rental (return_date IS NULL).
For each film I also show who rented it last and when.

About speed. The search by title reads the whole film table, because a pattern
that starts with % cannot use a normal index. The film table is small so it is fine,
for a big table a pg_trgm index would help. The rental table is the big one,
so I first filter films by title and only then check stock and last rental for
these few films. NOT EXISTS stops at the first open rental. I do not call
inventory_in_stock() for every copy because it runs two extra queries each time.
For the last rental LATERAL with LIMIT 1 takes one row per film, not all rentals.

row_num is made by ROW_NUMBER() sorted by title, it starts from 1.

If many films match, all of them are shown, one row per film.
If nothing matches, the function returns one row with the text
"Movie with title ... was not found in stock" and also a NOTICE.
If a film was never rented, customer and date are just NULL.
An empty pattern or NULL gives RAISE EXCEPTION, because it would return every film.
*/
-- CREATE OR REPLACE cannot change the result columns of a function, so if an older
-- version with other columns exists, I drop it first
DROP FUNCTION IF EXISTS core.films_in_stock_by_title(TEXT);

CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(
    p_title_pattern TEXT
)
RETURNS TABLE (
    "Row_num"       BIGINT,
    "Film title"    TEXT,
    "Language"      TEXT,
    "Customer name" TEXT,
    "Rental date"   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pattern TEXT;
BEGIN
    IF p_title_pattern IS NULL OR TRIM(REPLACE(p_title_pattern, '%', '')) = '' THEN
        RAISE EXCEPTION 'Please pass a part of the title, for example ''%%love%%''';
    END IF;

    -- add % if the user forgot them
    v_pattern := TRIM(p_title_pattern);
    IF POSITION('%' IN v_pattern) = 0 THEN
        v_pattern := '%' || v_pattern || '%';
    END IF;

    RETURN QUERY
    WITH matched_films AS (
        SELECT f.film_id, f.title, f.language_id
        FROM public.film AS f
        WHERE f.title ILIKE v_pattern
    ),
    films_in_stock AS (
        -- at least one copy is not rented right now
        SELECT mf.film_id, mf.title, mf.language_id
        FROM matched_films AS mf
        WHERE EXISTS (
            SELECT 1
            FROM public.inventory AS i
            WHERE i.film_id = mf.film_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.rental AS r
                  WHERE r.inventory_id = i.inventory_id
                    AND r.return_date IS NULL
              )
        )
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY s.title, s.film_id),
        s.title::TEXT,
        TRIM(l.name)::TEXT,
        (cu.first_name || ' ' || cu.last_name)::TEXT,
        last_rental.rental_date::TIMESTAMPTZ
    FROM films_in_stock AS s
    INNER JOIN public.language AS l ON l.language_id = s.language_id
    LEFT JOIN LATERAL (
        SELECT r.rental_date, r.customer_id
        FROM public.rental    AS r
        INNER JOIN public.inventory AS i ON i.inventory_id = r.inventory_id
        WHERE i.film_id = s.film_id
        ORDER BY r.rental_date DESC
        LIMIT 1
    ) AS last_rental ON TRUE
    LEFT JOIN public.customer AS cu ON cu.customer_id = last_rental.customer_id
    ORDER BY 1;

    -- FOUND is false when the query above gave no rows
    IF NOT FOUND THEN
        RAISE NOTICE 'Movie with title % was not found in stock', p_title_pattern;
        RETURN QUERY
        SELECT
            NULL::BIGINT,
            format('Movie with title %s was not found in stock', p_title_pattern),
            NULL::TEXT,
            NULL::TEXT,
            NULL::TIMESTAMPTZ;
    END IF;
END;
$$;

/*
Test 1, several films match, numbered 1, 2, 3 and so on:
SELECT * FROM core.films_in_stock_by_title('%love%');

Test 2, no % and big letters, the result is the same as test 1:
SELECT * FROM core.films_in_stock_by_title('LOVE');

Test 3, nothing found, one row with the "not found in stock" message:
SELECT * FROM core.films_in_stock_by_title('%qwertyxyz%');

Test 4, only % signs, gives an error:
SELECT * FROM core.films_in_stock_by_title('%%');
*/


-- Task 5. Procedure language function new_movie

-- Default language is Klingon, but the database does not have it, so every call with
-- the default would fail. I add it once. NOT EXISTS stops it from being added twice.
INSERT INTO public.language (name)
SELECT 'Klingon'
WHERE NOT EXISTS (
    SELECT 1
    FROM public.language
    WHERE LOWER(TRIM(name)) = 'klingon'
);

/*
The new film_id is not written by me. The column has a sequence, it is like a counter,
and each INSERT takes the next free number. Two films cannot get the same id this way.
RETURNING film_id gives back the number that was made.

Before the insert I look for the same title. Case and spaces do not matter, so
'Love Story' and ' LOVE STORY ' count as one film. If it is already there,
RAISE EXCEPTION stops everything and nothing is added. I save the title in big
letters because all titles in dvd_rental look like that.
pg_advisory_xact_lock is for the case when two people add the same title at the
same second. The second one waits for the first one, and then its check finds
the duplicate.

The language is found by name in the language table, so I do not hardcode any id.
If it is not found, RAISE EXCEPTION.

The whole function is one transaction. If something fails, like a duplicate, a wrong
year or any database error, PostgreSQL cancels all of it and the table stays the same.
All checks are done before the INSERT, language_id is a real id from the language
table, and the year must be between 1901 and 2155 because the year column allows
only these values. So the data stays correct.
*/
CREATE OR REPLACE FUNCTION core.new_movie(
    p_title        TEXT,
    p_release_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
    p_language     TEXT    DEFAULT 'Klingon'
)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_title        TEXT;
    v_release_year INTEGER;
    v_language_id  INTEGER;
    v_existing_id  INTEGER;
    v_new_film_id  INTEGER;
BEGIN
    IF p_title IS NULL OR TRIM(p_title) = '' THEN
        RAISE EXCEPTION 'Movie title cannot be empty';
    END IF;
    v_title := UPPER(TRIM(p_title));

    -- NULL year means this year
    v_release_year := COALESCE(p_release_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
    IF v_release_year < 1901 OR v_release_year > 2155 THEN
        RAISE EXCEPTION 'Release year % is not valid, it must be between 1901 and 2155', v_release_year;
    END IF;

    -- NULL language means Klingon
    SELECT l.language_id
    INTO v_language_id
    FROM public.language AS l
    WHERE LOWER(TRIM(l.name)) = LOWER(TRIM(COALESCE(p_language, 'Klingon')))
    ORDER BY l.language_id
    LIMIT 1;

    IF v_language_id IS NULL THEN
        RAISE EXCEPTION 'Language "%" does not exist in the language table', COALESCE(p_language, 'Klingon');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(LOWER(v_title)));

    SELECT f.film_id
    INTO v_existing_id
    FROM public.film AS f
    WHERE LOWER(TRIM(f.title)) = LOWER(v_title)
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        RAISE EXCEPTION 'Movie "%" already exists (film_id = %)', v_title, v_existing_id;
    END IF;

    INSERT INTO public.film (
        title, release_year, language_id,
        rental_duration, rental_rate, replacement_cost
    )
    VALUES (
        v_title, v_release_year, v_language_id,
        3, 4.99, 19.99
    )
    RETURNING film_id INTO v_new_film_id;

    RAISE NOTICE 'Movie "%" was added with film_id = %', v_title, v_new_film_id;
    RETURN v_new_film_id;
END;
$$;

/*
Test 1, only the title, so it uses this year and Klingon. It returns the new id.
SELECT core.new_movie('My Test Movie');
Then I check the row, it should have 3 days, 4.99 and 19.99:
SELECT film_id, title, release_year, language_id, rental_duration, rental_rate, replacement_cost
FROM public.film
WHERE title = 'MY TEST MOVIE';

Test 2, all parameters given:
SELECT core.new_movie('My Second Movie', 2020, 'English');

Test 3, same title again in small letters, gives "already exists" and adds nothing:
SELECT core.new_movie('my test movie');

Test 4, a language that is not in the table, gives an error:
SELECT core.new_movie('Another Movie', 2020, 'Elvish');

Test 5, wrong year, gives an error:
SELECT core.new_movie('Old Movie', 1500);

To clean up after testing:
DELETE FROM public.film WHERE title IN ('MY TEST MOVIE', 'MY SECOND MOVIE');
*/
