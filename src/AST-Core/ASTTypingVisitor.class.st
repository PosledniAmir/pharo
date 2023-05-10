"
A very simple and fast type inferer.

I'm a work in progress.

I'm not sound nor complete but my concern is to be usaful and fast when accuracy is not a concern (completion, user feedback, etc.).
I approximate the types to `RBValueNode` instances, `Variable` instance, and return values of `CompiledMethod`.

On AST nodes, type are stored in the `#type` property. Two instance variable dictionaries are used to store the types of variables and metod returns.

A type is represented with a single class.
`nil` represent the bottom element of the type lattice and `ProtoObject` should be the top element.

I do not have intraprocedural sensitivity (not flow-sensitive, nor path-sensitive).
I have a limited interprocedural capabilities as types of arguments are not propagated to the parameters --- so I'm circumstantialy context-sensitive :P.

A single visitor can be used on multiple methods.
This will help sharing the contextual information on interprocedural analysis (types of ivar for instance).

Instance variables:

* variableTypes <Dictionnary> associate assigned Variable objects with a type
* returnTypes <Dictionnary> associate return of compiled method with a type
* shortcutKernelMessages <True> activate some heuristics based on core seletors introduced in `Kernel` (for `Object`, `Class` or `Collection` for instance).
* dirty <Boolean> used for basic fixed-point analysis when more than on pass is needed
"
Class {
	#name : #ASTTypingVisitor,
	#superclass : #RBProgramNodeVisitor,
	#instVars : [
		'variableTypes',
		'unknownMethod',
		'shortcutKernelMessages',
		'returnTypes',
		'dirty'
	],
	#category : #'AST-Core-Type'
}

{ #category : #analyzing }
ASTTypingVisitor >> fixedPointAnalysis: aNode [
	"Repeat the analysis until a fixed point is reached.
	Because the analysis is monotonous and the height of the latice is bounded, a fixed point is reachable in finite time."

	[
	dirty := false.
	self visit: aNode.
	dirty ] whileTrue
]

{ #category : #initialization }
ASTTypingVisitor >> initialize [

	variableTypes := Dictionary new.
	returnTypes := Dictionary new.
	unknownMethod := Set new.
	shortcutKernelMessages := true
]

{ #category : #lattice }
ASTTypingVisitor >> merge: types [

	^ types reduce: [ :t1 :t2 | self merge: t1 with: t2 ]
]

{ #category : #lattice }
ASTTypingVisitor >> merge: type1 with: type2 [
	"Do a join operation on the two type, so return the common super class.
	`nil` behave as a bottom element of a lattice.
	`ProtoObject` should behave as a top element.
	
	`UndefinedObject` is also managed as just above nil but bellow all other types."

	| aSuperclass |
	type1 ifNil: [ ^ type2 ].
	type2 ifNil: [ ^ type1 ].
	type1 == UndefinedObject ifTrue: [ ^ type2 ].
	type2 == UndefinedObject ifTrue: [ ^ type1 ].
	type1 == type2 ifTrue: [ ^ type1 ].

	aSuperclass := type1.
	[ aSuperclass isNotNil ] whileTrue: [
		type2 == aSuperclass ifTrue: [ ^ aSuperclass ].
		(type2 inheritsFrom: aSuperclass) ifTrue: [ ^ aSuperclass ].
		aSuperclass := aSuperclass superclass ].

	self error: 'This should not occurs, unless multiple roots?'
]

{ #category : #accessing }
ASTTypingVisitor >> shortcutKernelMessages [

	^ shortcutKernelMessages
]

{ #category : #accessing }
ASTTypingVisitor >> shortcutKernelMessages: anObject [

	shortcutKernelMessages := anObject
]

{ #category : #lattice }
ASTTypingVisitor >> typeMethod: aCompilerMethod with: aClass [

	| type |
	type := aClass.
	returnTypes at: aCompilerMethod ifPresent: [ :oldType |
		oldType = type ifTrue: [ ^ self ].
		type := self merge: oldType with: type.
		oldType = type ifTrue: [ ^ self ] ].

	dirty := true.
	returnTypes at: aCompilerMethod put: type
]

{ #category : #lattice }
ASTTypingVisitor >> typeNode: aNode with: aClass [
	"We assume monotonicity here, so no need to merge with the oldType."

	aNode
		propertyAt: #type
		ifPresent: [ :oldType | oldType = aClass ifTrue: [ ^ self ] ].

	dirty := true.
	aNode propertyAt: #type put: aClass
]

{ #category : #lattice }
ASTTypingVisitor >> typeVariable: aVariable with: aClass [

	| type |
	type := aClass.
	variableTypes at: aVariable ifPresent: [ :oldType |
		oldType = type ifTrue: [ ^ self ].
		type := self merge: oldType with: type.
		oldType = type ifTrue: [ ^ self ] ].

	dirty := true.
	variableTypes at: aVariable put: type
]

{ #category : #accessing }
ASTTypingVisitor >> unknownMethod [

	^ unknownMethod
]

{ #category : #visiting }
ASTTypingVisitor >> visitArrayNode: aLiteralNode [

	super visitArrayNode: aLiteralNode.
	self typeNode: aLiteralNode with: Array
]

{ #category : #visiting }
ASTTypingVisitor >> visitAssignmentNode: anAssignmentNode [

	| type variable |
	super visitAssignmentNode: anAssignmentNode.

	type := anAssignmentNode value propertyAt: #type ifAbsent: [ ^ self ].
	self typeNode: anAssignmentNode with: type.

	variable := anAssignmentNode variable variable originalVar.
	self typeVariable: variable with: type
]

{ #category : #visiting }
ASTTypingVisitor >> visitBlockNode: aNode [

	super visitBlockNode: aNode.
	self typeNode: aNode with: BlockClosure
]

{ #category : #visiting }
ASTTypingVisitor >> visitGlobalNode: aGlobalNode [

	self typeNode: aGlobalNode with: aGlobalNode binding read class
]

{ #category : #visiting }
ASTTypingVisitor >> visitLiteralArrayNode: aLiteralNode [

	super visitLiteralArrayNode: aLiteralNode.
	self typeNode: aLiteralNode with: Array
]

{ #category : #visiting }
ASTTypingVisitor >> visitLiteralNode: aLiteralNode [

	self typeNode: aLiteralNode with: aLiteralNode value class
]

{ #category : #visiting }
ASTTypingVisitor >> visitMessageNode: aNode [

	| recvType method |
	super visitMessageNode: aNode.

	"Fast path for some special Kernel selectors (type of the receiver is not important)"
	shortcutKernelMessages ifTrue: [
		(#( = == ~= ~~ < > <= >= isNil isNotNil isEmpty ) includes:
			 aNode selector) ifTrue: [ ^ self typeNode: aNode with: Boolean ].

		(#( size ) includes: aNode selector) ifTrue: [
			^ self typeNode: aNode with: Integer ] ].

	recvType := aNode receiver propertyAt: #type ifAbsent: [ ^ self ].

	"Fast path for some special Kernel selectors (type of the receiver IS important)"
	shortcutKernelMessages ifTrue: [
		(recvType isMeta and: [
			 #( new new: basicNew basicNew: ) includes: aNode selector ])
			ifTrue: [ ^ self typeNode: aNode with: recvType instanceSide ].

		aNode selector == #class ifTrue: [
			^ self typeNode: aNode with: recvType class ] ].

	"Method lookup. This one is not sound because we only consider a sigle static type and a single method,
	at runtime, the concrete receiver type might be numerous and different."
	method := recvType lookupSelector: aNode selector.
	returnTypes
		at: method
		ifPresent: [ :type | ^ self typeNode: aNode with: type ].
	unknownMethod add: method
]

{ #category : #visiting }
ASTTypingVisitor >> visitMethodNode: aNode [

	super visitMethodNode: aNode.
	aNode compiledMethod ifNil: [ ^ self ].

	"Do not polute the return value since the method will fail"
	aNode compiledMethod isSubclassResponsibility ifTrue: [ ^ self ].

	"Fallback at an implicit return self"
	aNode containsReturn ifFalse: [
		self typeMethod: aNode compiledMethod with: aNode methodClass ]
]

{ #category : #visiting }
ASTTypingVisitor >> visitReturnNode: aNode [

	| type |
	super visitReturnNode: aNode.

	type := aNode value propertyAt: #type ifAbsent: [ ^ self ].
	aNode methodNode compiledMethod ifNotNil: [ :cm |
		self typeMethod: cm with: type ]
]

{ #category : #visiting }
ASTTypingVisitor >> visitSelfNode: aSelfNode [
	self typeNode: aSelfNode with: aSelfNode methodNode methodClass
]

{ #category : #visiting }
ASTTypingVisitor >> visitSuperNode: aSuperNode [
	| class |
	class := aSuperNode methodNode methodClass.
	"the type of super of a Trait is not known"
	class isTrait ifTrue: [ ^self ].
	self typeNode: aSuperNode with: class superclass
]

{ #category : #visiting }
ASTTypingVisitor >> visitVariableNode: aNode [

	| type variable |
	aNode isError ifTrue: [ ^ self ].
	variable := aNode variable originalVar.
	type := variableTypes at: variable ifAbsent: [ ^ self ].
	self typeNode: aNode with: type.
]