/*
 График погашения кредита
 
 Данный запрос строит помесячный график платежей по кредиту от даты предоставления до даты окончания займа, исходя из данных, которые определяются при выдаче кредита.
 Используемая СУБД: Microsoft SQL Server 2022.
 Названия таблиц баз данных, константных значений в формулах, а также некоторых полей таблиц были переименованы или изменены.
*/

DROP TABLE IF EXISTS #credit_info_table, #rates_info_table, #insurance_info_table, #main_table, #result_table, #graph_table

DECLARE

@idDog nchar(8) = '12345678', -- номер договора

@rate_1 decimal(7,4), -- процентная ставка №1
@rate_2 decimal(7,4), -- процентная ставка №2
@total_months int, -- общее количество месяцев от даты предоставления до даты погашения
@months_to_end_r1 int, -- количество месяцев до конца периода по ставке №1
@months_to_end_r2 int, -- оставшееся количество месяцев до погашения кредита по ставке №2
@first_pay_date date, -- дата первого платежа
@principal_payment_r1 int = 1, -- гашение основного долга за месяц в период действия ставки №1
@annuity decimal(18,4), -- выплата по аннуитету после "ступеньки"
@debt_balance decimal(18,4), -- остаток основного долга
@next_month_pay_date date, -- дата последующего платежа
@interest_payment decimal(18,4), -- платеж погашения процентов
@principal_payment decimal(18,4), -- платеж погашения основной суммы кредита
@insurance_amount decimal(18,4), -- сумма страхования предмета залога
@count int = 0 -- счетчик для цикла


/*
 Сбор основных данных по кредиту.
 В таблице CreditContractsInfo содержатся основные данные по займам: даты открытия-закрытия, ставка при выдаче, сумма кредита и т.д.
*/
SELECT [idDog],
	   [dOpen],
	   [dEnd],
	   IIF(DAY([dOpen]) >= DAY([dEnd]),
	    DATEDIFF(month, [dOpen], [dEnd]),
		DATEDIFF(month, [dOpen], [dEnd]) + 1) AS [total_months], -- определяем точное количество месяцев действия кредита
	   [amount],
	   [rate],
	   [row_created]
  INTO #credit_info_table
  FROM (SELECT *,
			   ROW_NUMBER() OVER(ORDER BY [row_created]) AS [rn] -- берем первую запись из таблицы, так как нас интересует процентная ставка при выдаче
		  FROM [CreditContractsInfo]
		 WHERE [idDog] = @idDog) t
 WHERE [rn] = 1


/*
 Поиск данных по изменению кредитной ставки.
 В таблице CreditActions содержатся все операции над кредитом, нас интересует "Изменение ставки".
 В таблице DetailedCreditActions расшифрованные данные по каждой операции из CreditActions.
*/
SELECT *
  INTO #rates_info_table
  FROM [DetailedCreditActions]
 WHERE [refer] = (SELECT [refer]
				    FROM (SELECT [refer],
							     ROW_NUMBER() OVER(ORDER BY [row_created]) AS [rn] -- также нас интересует первое изменение процентной ставки после выдачи кредита
						    FROM [CreditActions]
						   WHERE [IdDog] = @idDog
						     AND [Name] = 'Изменение ставки'
							 AND [row_created] = (SELECT [row_created] FROM #credit_info_table)) t
				   WHERE [rn] = 1)

/*
 Подтягиваем данные по страхованию кредита.
 В таблице InsuranceInfo содержится информация о страховых выплатах по кредиту.
*/
SELECT [request_id],
	   [accident_insurance_interest],
	   [term_insurance],
	   [sum_insurance_total]
  INTO #insurance_info_table
  FROM (SELECT *,
			   ROW_NUMBER() OVER(PARTITION BY [request_id] ORDER BY [row_created] DESC) AS [rn] -- в этом случае берется последняя запись
		  FROM [InsuranceInfo]
		 WHERE [request_id] = @idDog) t
 WHERE [rn] = 1


/* Расчёт постоянных величин исходя из полученных данных */
SET @rate_1 = (SELECT CAST([rate] AS decimal(7,4)) FROM #credit_info_table) / 100

SET @rate_2 = CASE WHEN (SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'rate_wi') IS NOT NULL -- поиск второй ставки кредита. В первую очередь берется ставка со страховкой, при отсутсвии - без страховки.
					AND (SELECT CAST([Value] AS decimal(7,4)) FROM #rates_info_table WHERE [nameKod] = 'rate_wi') != 0 -- если нет обоих вариантов ставок, то у займа отсутствует перемена условий.
				   THEN (SELECT CAST([Value] AS decimal(7,4)) FROM #rates_info_table WHERE [nameKod] = 'rate_wi') / 100
				   WHEN (SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'rate_ni') IS NOT NULL
				    AND (SELECT CAST([Value] AS decimal(7,4)) FROM #rates_info_table WHERE [nameKod] = 'rate_ni') != 0
				   THEN (SELECT CAST([Value] AS decimal(7,4)) FROM #rates_info_table WHERE [nameKod] = 'rate_ni') / 100
				   ELSE @rate_1 END

SET @months_to_end_r1 = COALESCE(IIF(DAY((SELECT [dOpen] FROM #credit_info_table)) >= DAY((SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'date_change')), -- расчет количества месяцев действия 1-й ставки.
						         DATEDIFF(month, (SELECT [dOpen] FROM #credit_info_table), (SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'date_change')),
								 DATEDIFF(month, (SELECT [dOpen] FROM #credit_info_table), (SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'date_change')) + 1), 0)

SET @total_months = (SELECT [total_months] FROM #credit_info_table)

SET @debt_balance = (SELECT [amount] FROM #credit_info_table)

SET @months_to_end_r2 = @total_months - @months_to_end_r1

SET @annuity = ROUND((@debt_balance - @months_to_end_r1 * @principal_payment_r1)
				 * ((@rate_2 / 12) + (@rate_2 / 12) / (POWER(((@rate_2 / 12) + 1), @months_to_end_r2) - 1)), -1) -- рассчет аннуитетного платежа по формуле

SET @first_pay_date = CASE WHEN (SELECT [Value] FROM #rates_info_table WHERE [nameKod] = 'date_change') IS NOT NULL -- при наличии только даты, когда будет первый платеж по новой ставке, исчисляем дату первого платежа
						   THEN (SELECT DATEADD(month, -1 * @months_to_end_r1 + 1, [Value]) FROM #rates_info_table WHERE [nameKod] = 'date_change')
						   ELSE (SELECT DATEADD(month, 1, [dOpen]) FROM #credit_info_table) END -- при ее отсутствии принимаем, что 1-й платеж будет через месяц после предоставления займа


/* Создание таблицы для расчетных операций, определение типов данных у полей */
CREATE TABLE #main_table(
	   [Месяц] int,
	   [Дата платежа] date,
	   [ОД на начало месяца] decimal(18,4),
	   [Процентная ставка] decimal(7,4),
	   [Гашение ОД] decimal(18,4),
	   [Гашение процентов] decimal(18,4),
	   [Сумма страхования залога] decimal(18,4),
	   [Сумма личного страхования] decimal(18,4)
	   )


/* Определение 0-й строки данных. Это необходимо для того, чтобы при дальнейших расчетах обращаться к предыдущей строке */
INSERT INTO #main_table
VALUES(@count,
	   (SELECT [dOpen] FROM #credit_info_table),
	   @debt_balance,
	   0,
	   0,
	   0,
	   0,
	   0
	   )


/* Создание итоговой таблицы, идентичной расчетной. Также добавляется уже определенная 0-я строка */
SELECT *
  INTO #result_table
  FROM #main_table


/* Определение цикла. Он состоит из количества итераций, равных общему количеству месяцев, на которое выдан кредит */
WHILE @count < @total_months
BEGIN

/* Расчет параметров на следующий месяц */
SET @count += 1

SET @next_month_pay_date = DATEADD(month, @count - 1, @first_pay_date)

SET @interest_payment = CASE WHEN MONTH((SELECT [Дата платежа] FROM #main_table)) = 12 -- если следующий платеж в январе, то необходимо учесть смену года на високосный. Декабрьский платеж отличается от январского
							 THEN

					    (SELECT IIF(@count <= @months_to_end_r1, @rate_1, @rate_2) -- формула вычисления платежа по процентам
							    / CASE WHEN YEAR([Дата платежа]) % 4 = 0 AND YEAR([Дата платежа]) % 100 != 0 THEN 366 -- алгоритм определения количества дней в году (проверка на високосный год)
									   WHEN YEAR([Дата платежа]) % 400 = 0 THEN 366
									   ELSE 365 END
						        * DATEDIFF(day, [Дата платежа], EOMONTH([Дата платежа]))
								* [ОД на начало месяца]
						   FROM #main_table)
							    +
					    (SELECT IIF(@count <= @months_to_end_r1, @rate_1, @rate_2)
							    / CASE WHEN YEAR(@next_month_pay_date) % 4 = 0 AND YEAR(@next_month_pay_date) % 100 != 0 THEN 366
									   WHEN YEAR(@next_month_pay_date) % 400 = 0 THEN 366
									   ELSE 365 END
						        * DATEDIFF(day, EOMONTH([Дата платежа]), @next_month_pay_date)
								* [ОД на начало месяца]
						   FROM #main_table)

							 ELSE

					    (SELECT IIF(@count <= @months_to_end_r1, @rate_1, @rate_2)
							    / CASE WHEN YEAR(@next_month_pay_date) % 4 = 0 AND YEAR(@next_month_pay_date) % 100 != 0 THEN 366
									   WHEN YEAR(@next_month_pay_date) % 400 = 0 THEN 366
									   ELSE 365 END
						        * DATEDIFF(day, [Дата платежа], @next_month_pay_date)
								* [ОД на начало месяца]
						   FROM #main_table)
						     END

SET @principal_payment = (SELECT IIF(@count <= @months_to_end_r1, @principal_payment_r1,
									IIF(@count = @total_months OR (SELECT [ОД на начало месяца] FROM #main_table) < @principal_payment, (SELECT [ОД на начало месяца] FROM #main_table),
										IIF(@interest_payment > @annuity, 0, @annuity - @interest_payment))))

SET @insurance_amount = IIF(MONTH(@next_month_pay_date) = MONTH((SELECT [dOpen] FROM #credit_info_table)) -- формула вычисления платежа по страхованию залогового имущества
					     AND YEAR(@next_month_pay_date) != YEAR((SELECT [dOpen] FROM #credit_info_table)),
						   (SELECT ([ОД на начало месяца] - @principal_payment) * 1.3 * 0.007
							  FROM #main_table), 0)


IF @principal_payment = 0 AND @interest_payment = 0 -- прерывание цикла на случай, если кредит погашается раньше срока
BREAK



/* Обновление данных в рабочей таблице, исходя из увеличения интервала на 1 месяц */
UPDATE #main_table
   SET [Месяц] = @count,
	   [Дата платежа] = @next_month_pay_date,
	   [ОД на начало месяца] = [ОД на начало месяца] - @principal_payment,
       [Процентная ставка] = IIF(@count <= @months_to_end_r1, @rate_1, @rate_2),
	   [Гашение процентов] = @interest_payment,
	   [Гашение ОД] = @principal_payment,
	   [Сумма страхования залога] = @insurance_amount


/* Запись данных в результирующую таблицу, исходя из увеличения интервала на 1 месяц */
INSERT INTO #result_table
SELECT [Месяц],
	   [Дата платежа],
	   [ОД на начало месяца],
	   [Процентная ставка],
	   [Гашение ОД],
	   [Гашение процентов],
	   [Сумма страхования залога],
	   [Сумма личного страхования]
  FROM #main_table

END


/* Выбор необходимых столбцов после всех расчетов, добавление 0-й строки с первоначальными параметрами */
SELECT [Дата платежа],
       [Погашение основной суммы кредита] + [Погашение процентов] AS [Сумма платежа],
	   [Погашение основной суммы кредита],
	   [Погашение процентов],
	   CAST([Сумма страхования залога]AS decimal(18,4)) AS [Сумма страхования залога],
	   CAST([Сумма личного страхования] AS decimal(18,4)) AS [Сумма личного страхования],
	   ABS(SUM([Погашение основной суммы кредита]) OVER(ORDER BY [Дата платежа])) AS [Остаток задолженности по кредиту],
	   [Процентная ставка]
  INTO #graph_table
  FROM (SELECT [Дата платежа],
		       [Гашение ОД] AS [Погашение основной суммы кредита],
		       [Гашение процентов] AS [Погашение процентов],
		       [Процентная ставка],
			   [Сумма страхования залога],
		       [Сумма личного страхования]
	      FROM #result_table
		 WHERE [Месяц] != 0
		 UNION
		SELECT (SELECT [dOpen] FROM #credit_info_table),
			   @debt_balance * (-1),
			   0,
			   0,
			   @debt_balance * 1.3 * 0.007,
			   (SELECT [sum_insurance_total] FROM #insurance_info_table)) t
 ORDER BY [Дата платежа]


SELECT CAST([Дата платежа] AS nvarchar(10)) AS [Дата платежа],
       CAST([Сумма платежа] AS money) AS [Сумма платежа], -- тип данных "money" удобен при переносе полученного результата запроса в Excel-таблицу, поскольку в этом числовом типе данных знак-разделитель ","
	   CAST([Погашение основной суммы кредита] AS money) AS [Погашение основной суммы кредита],
	   CAST([Погашение процентов] AS money) AS [Погашение процентов],
	   CAST([Сумма страхования залога] AS money) AS [Сумма страхования залога],
	   CAST([Сумма личного страхования] AS money) AS [Сумма личного страхования],
	   CAST([Остаток задолженности по кредиту] AS money) AS [Остаток задолженности по кредиту],
	   CAST([Процентная ставка] AS nvarchar(10)) AS [Процентная ставка]
  FROM #graph_table
 UNION
SELECT 'Итого', -- добавление итоговых сумм в результирующую таблицу
       0,
	   CAST((SELECT SUM([Погашение основной суммы кредита]) FROM #graph_table WHERE [Погашение основной суммы кредита] >= 0) AS money),
	   CAST((SELECT SUM([Погашение процентов]) FROM #graph_table) AS money),
	   CAST((SELECT SUM([Сумма страхования залога]) FROM #graph_table) AS money),
	   CAST((SELECT SUM([Сумма личного страхования]) FROM #graph_table) AS money),
	   0,
	   ''
