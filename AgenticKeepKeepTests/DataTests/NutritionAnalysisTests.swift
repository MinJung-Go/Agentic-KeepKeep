import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class NutritionAnalysisTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.inMemory())
    }

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
    }

    private func makeMeal(
        in context: ModelContext,
        daysAgo days: Int,
        calories: Double,
        protein: Double,
        carbs: Double = 0,
        fat: Double = 0
    ) {
        let meal = MealEntry(date: daysAgo(days), mealType: .lunch)
        context.insert(meal)
        let food = FoodItem(name: "测试", calories: calories, proteinG: protein, carbsG: carbs, fatG: fat)
        food.meal = meal
        context.insert(food)
    }

    func testEmptyAnalysis() {
        let analysis = NutritionAnalysis.build(meals: [], latestWeightKg: 75, daysInRange: 7)

        XCTAssertFalse(analysis.hasData)
        XCTAssertEqual(analysis.avgCalories, 0)
        XCTAssertTrue(analysis.insight.contains("还没有饮食记录"))
    }

    func testAveragesOverLoggedDaysOnly() throws {
        let context = try makeContext()

        // 第 1 天：2000 kcal / 100g 蛋白；第 3 天：1000 kcal / 60g 蛋白
        makeMeal(in: context, daysAgo: 1, calories: 2_000, protein: 100)
        makeMeal(in: context, daysAgo: 3, calories: 1_000, protein: 60)
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: 75, daysInRange: 7)

        XCTAssertEqual(analysis.daysLogged, 2)
        XCTAssertEqual(analysis.avgCalories, 1_500, accuracy: 1)
        XCTAssertEqual(analysis.avgProteinG, 80, accuracy: 1)
        XCTAssertEqual(analysis.loggingCoverage, 2.0 / 7.0, accuracy: 0.001)
    }

    func testProteinTargetAndGap() throws {
        let context = try makeContext()
        makeMeal(in: context, daysAgo: 1, calories: 1_800, protein: 80)
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: 75, daysInRange: 7)

        // 目标 = 75 × 1.6 = 120g，缺口 = 40g
        XCTAssertEqual(analysis.proteinTargetG ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(analysis.proteinGapG ?? 0, 40, accuracy: 0.01)
        XCTAssertTrue(analysis.insight.contains("还差"))
    }

    func testProteinTargetMet() throws {
        let context = try makeContext()
        makeMeal(in: context, daysAgo: 1, calories: 2_200, protein: 130)
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: 75, daysInRange: 7)

        XCTAssertEqual(analysis.proteinGapG ?? -1, 0, accuracy: 0.01)
        XCTAssertTrue(analysis.insight.contains("已达目标"))
    }

    func testNoWeightMeansNoTarget() throws {
        let context = try makeContext()
        makeMeal(in: context, daysAgo: 1, calories: 1_800, protein: 80)
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: nil, daysInRange: 7)

        XCTAssertNil(analysis.proteinTargetG)
        XCTAssertNil(analysis.proteinGapG)
        XCTAssertTrue(analysis.insight.contains("蛋白质日均"))
    }

    func testLowCoverageIsCalledOut() throws {
        let context = try makeContext()
        makeMeal(in: context, daysAgo: 1, calories: 1_800, protein: 90)
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: 75, daysInRange: 14)

        XCTAssertTrue(analysis.insight.contains("记录天数偏少"))
    }

    func testMacroTotalsAggregateAcrossItems() throws {
        let context = try makeContext()

        let meal = MealEntry(date: daysAgo(1), mealType: .dinner)
        context.insert(meal)
        for (calories, protein) in [(300.0, 20.0), (500.0, 40.0)] {
            let food = FoodItem(name: "菜", calories: calories, proteinG: protein, carbsG: 30, fatG: 10)
            food.meal = meal
            context.insert(food)
        }
        try context.save()

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let analysis = NutritionAnalysis.build(meals: meals, latestWeightKg: 70, daysInRange: 7)

        XCTAssertEqual(analysis.avgCalories, 800, accuracy: 0.01)
        XCTAssertEqual(analysis.avgProteinG, 60, accuracy: 0.01)
        XCTAssertEqual(analysis.avgCarbsG, 60, accuracy: 0.01)
        XCTAssertEqual(analysis.avgFatG, 20, accuracy: 0.01)
    }
}
