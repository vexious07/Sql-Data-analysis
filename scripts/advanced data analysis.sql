--analysing total sales per year  
select 
datetrunc(month, order_date) as order_date,
sum(sales_amount) as total_sales,
count(distinct customer_key) as total_customers
from gold.fact_sales
where order_date is not null
group by datetrunc(month, order_date)
order by datetrunc(month, order_date)

--calculating the total sales per month + running total of sales overtime
select 
order_month,
total_sales,
-- window functions
sum(total_sales) over (order by order_month) as running_total_sales --comulative aggrigation 
from
(
	select
	month(order_date) as order_month,
	sum(sales_amount) as total_sales
	from gold.fact_sales
	where order_date is not null
	group by month(order_date)
) t

 --performance analysis
 /* analyze the yearly performance of products by comparing their sales
 to both the aveerage sales performance of the product and the previous years sales */ 
 with yearly_product_Sales as ( -- CTE
 select 
 year(f.order_date) as order_year,
 p.product_name,
 sum(f.sales_amount) as current_sales
 from gold.fact_sales f
	 left join gold.dim_products p
	 on p.product_key = f.product_key
	 where f.order_date is not null
	 group by
	year(f.order_date),
	p.product_name
	)

	select 
	order_year,
	product_name,
	current_sales,
	avg(current_sales) over (partition by product_name) as average_sales,
	current_sales - avg(current_sales) over (partition by product_name) as diference_avg_and_current_sales,
	case when current_sales - avg(current_sales) over (partition by product_name) > 0 then 'making money'
		 when current_sales - avg(current_sales) over (partition by product_name) < 0 then 'Losing money'
		 else 'avg_change'
	end avg_change,
	-- year over year analysis (can be change to  month over month just change year)
	lag(current_sales) over (partition by product_name order by order_year) lastyear_sales,
	current_sales - lag(current_sales) over (partition by product_name order by order_year) diff_currnt_and_last_sales,
	case when current_sales - lag(current_sales) over (partition by product_name order by order_year) > 0 then 'Increase in profit'
		 WHEN current_sales - lag(current_sales) over (partition by product_name order by order_year) < 0 then  'Decrease in profit'
		 else 'Same'
	end yearly_change
	from yearly_product_Sales
	order by product_name, order_year

-- Which categories contribute the most to overall sales?
WITH category_sales AS (
    SELECT
        p.category,
        SUM(f.sales_amount) AS total_sales
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON p.product_key = f.product_key
    GROUP BY p.category
)
SELECT
    category,
    total_sales,
    SUM(total_sales) OVER () AS overall_sales,
    ROUND((CAST(total_sales AS FLOAT) / SUM(total_sales) OVER ()) * 100, 2) AS percentage_of_total
FROM category_sales
ORDER BY total_sales DESC;


-- Create gold.report_customers

IF OBJECT_ID('gold.report_customers', 'V') IS NOT NULL
    DROP VIEW gold.report_customers;
GO

CREATE VIEW gold.report_customers AS

WITH base_query AS(

-- Base Query Retrieves core columns from tables

SELECT
f.order_number,
f.product_key,
f.order_date,
f.sales_amount,
f.quantity,
c.customer_key,
c.customer_number,
CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
DATEDIFF(year, c.birthdate, GETDATE()) age
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
ON c.customer_key = f.customer_key
WHERE order_date IS NOT NULL)

, customer_aggregation AS (

-- Customer Aggregations Summarizing key metrics at the customer level

SELECT 
	customer_key,
	customer_number,
	customer_name,
	age,
	COUNT(DISTINCT order_number) AS total_orders,
	SUM(sales_amount) AS total_sales,
	SUM(quantity) AS total_quantity,
	COUNT(DISTINCT product_key) AS total_products,
	MAX(order_date) AS last_order_date,
	DATEDIFF(month, MIN(order_date), MAX(order_date)) AS lifespan
FROM base_query
GROUP BY 
	customer_key,
	customer_number,
	customer_name,
	age
)
SELECT
customer_key,
customer_number,
customer_name,
age,
CASE 
	 WHEN age < 20 THEN 'Under 20'
	 WHEN age between 20 and 29 THEN '20-29'
	 WHEN age between 30 and 39 THEN '30-39'
	 WHEN age between 40 and 49 THEN '40-49'
	 ELSE '50 and above'
END AS age_group,
CASE 
    WHEN lifespan >= 12 AND total_sales > 5000 THEN 'VIP'
    WHEN lifespan >= 12 AND total_sales <= 5000 THEN 'Regular'
    ELSE 'New'
END AS customer_segment,
last_order_date,
DATEDIFF(month, last_order_date, GETDATE()) AS recency,
total_orders,
total_sales,
total_quantity,
total_products
lifespan,
-- Compuate average order value (AVO)
CASE WHEN total_sales = 0 THEN 0
	 ELSE total_sales / total_orders
END AS avg_order_value,
-- Compuate average monthly spend
CASE WHEN lifespan = 0 THEN total_sales
     ELSE total_sales / lifespan
END AS avg_monthly_spend
FROM customer_aggregation

-- Creating gold.report_products

IF OBJECT_ID('gold.report_products', 'V') IS NOT NULL
    DROP VIEW gold.report_products;
GO

CREATE VIEW gold.report_products AS

WITH base_query AS (
--Retrieves core columns from fact_sales and dim_products

    SELECT
	    f.order_number,
        f.order_date,
		f.customer_key,
        f.sales_amount,
        f.quantity,
        p.product_key,
        p.product_name,
        p.category,
        p.subcategory,
        p.cost
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON f.product_key = p.product_key
    WHERE order_date IS NOT NULL  -- only consider valid sales dates
),

product_aggregations AS (

-- Product Aggregation Summarizing key metrics at the product level

SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan,
    MAX(order_date) AS last_sale_date,
    COUNT(DISTINCT order_number) AS total_orders,
	COUNT(DISTINCT customer_key) AS total_customers,
    SUM(sales_amount) AS total_sales,
    SUM(quantity) AS total_quantity,
	ROUND(AVG(CAST(sales_amount AS FLOAT) / NULLIF(quantity, 0)),1) AS avg_selling_price
FROM base_query

GROUP BY
    product_key,
    product_name,
    category,
    subcategory,
    cost
)

-- Combine all product results into one output
SELECT 
	product_key,
	product_name,
	category,
	subcategory,
	cost,
	last_sale_date,
	DATEDIFF(MONTH, last_sale_date, GETDATE()) AS recency_in_months,
	CASE
		WHEN total_sales > 50000 THEN 'High-Performer'
		WHEN total_sales >= 10000 THEN 'Mid-Range'
		ELSE 'Low-Performer'
	END AS product_segment,
	lifespan,
	total_orders,
	total_sales,
	total_quantity,
	total_customers,
	avg_selling_price,
	-- Average Order Revenue
	CASE 
		WHEN total_orders = 0 THEN 0
		ELSE total_sales / total_orders
	END AS avg_order_revenue,

	-- Average Monthly Revenue
	CASE
		WHEN lifespan = 0 THEN total_sales
		ELSE total_sales / lifespan
	END AS avg_monthly_revenue

FROM product_aggregations 
